//! A persistent fork-join pool: the native frontend's per-call `std::thread` spawns, without the
//! spawns.
//!
//! `run(job)` publishes `job`, wakes parked workers and runs `job(0)` on the caller. A worker that
//! wakes runs `job(tid)` with its own `tid` in `1..threads`. Jobs claim their work through their
//! own atomic counters, so a worker that wakes late finds less (or nothing) to do and the caller
//! never waits for a thread that has not started. When the caller's share is done it retracts the
//! job and waits only for workers that entered it.
//!
//! Workers park as soon as they find no new job, so every call pays the wake-up a production
//! dictation (one frontend call per utterance) would pay.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, AtomicUsize, Ordering::SeqCst};
use std::thread::{self, JoinHandle};

type Job<'a> = dyn Fn(usize) + Sync + 'a;

/// The published job: a thin pointer to the caller's (fat) closure reference.
struct Slot {
    job: *const Job<'static>,
}

struct Shared {
    slot: AtomicPtr<Slot>,
    generation: AtomicU64,
    active: AtomicUsize,
    sleeping: Vec<AtomicBool>,
    panicked: AtomicBool,
    shutdown: AtomicBool,
}

pub struct Pool {
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

impl Pool {
    /// A pool of `threads` threads in total: the caller plus `threads - 1` workers.
    pub fn new(threads: usize) -> Pool {
        let n_workers = threads.max(1) - 1;
        let shared = Arc::new(Shared {
            slot: AtomicPtr::new(null_mut()),
            generation: AtomicU64::new(0),
            active: AtomicUsize::new(0),
            sleeping: (0..n_workers).map(|_| AtomicBool::new(false)).collect(),
            panicked: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
        });
        let workers = (0..n_workers)
            .map(|index| {
                let shared = Arc::clone(&shared);
                thread::Builder::new()
                    .name(format!("mel-frontend-{}", index + 1))
                    .spawn(move || worker(&shared, index))
                    .expect("spawn mel-frontend worker")
            })
            .collect();
        Pool { shared, workers }
    }

    /// Threads that can run a job, the caller included.
    pub fn threads(&self) -> usize {
        self.workers.len() + 1
    }

    /// Runs `job(0)` here and `job(tid)` on every worker that wakes before the caller is done.
    /// Panics (after every entered worker has left) if any thread's `job` panicked.
    pub fn run(&self, job: &Job<'_>) {
        // SAFETY: the reference is only reachable through `slot` until `Retract` (below, also on
        // unwind) has withdrawn it and waited for every worker that loaded it to leave.
        let job: &Job<'static> = unsafe { std::mem::transmute::<&Job<'_>, &Job<'static>>(job) };
        let slot = Slot { job };
        let shared = &*self.shared;
        shared.panicked.store(false, SeqCst);
        shared.slot.store(&slot as *const Slot as *mut Slot, SeqCst);
        shared.generation.fetch_add(1, SeqCst);
        for (index, handle) in self.workers.iter().enumerate() {
            if shared.sleeping[index].load(SeqCst) {
                handle.thread().unpark();
            }
        }
        let retract = Retract(shared);
        job(0);
        drop(retract);
        if shared.panicked.swap(false, SeqCst) {
            panic!("a mel-frontend worker panicked");
        }
    }
}

/// Withdraws the published job and waits for the workers inside it.
struct Retract<'a>(&'a Shared);

impl Drop for Retract<'_> {
    fn drop(&mut self) {
        self.0.slot.store(null_mut(), SeqCst);
        while self.0.active.load(SeqCst) != 0 {
            std::hint::spin_loop();
        }
    }
}

fn worker(shared: &Shared, index: usize) {
    let tid = index + 1;
    let mut seen = 0u64;
    loop {
        loop {
            if shared.shutdown.load(SeqCst) {
                return;
            }
            let generation = shared.generation.load(SeqCst);
            if generation != seen {
                seen = generation;
                break;
            }
            // Announce the park, then re-check: `run` bumps the generation before it reads
            // `sleeping`, so either it sees this flag and unparks, or this re-check sees its bump.
            shared.sleeping[index].store(true, SeqCst);
            if shared.generation.load(SeqCst) == seen && !shared.shutdown.load(SeqCst) {
                thread::park();
            }
            shared.sleeping[index].store(false, SeqCst);
        }
        // Enter, then confirm the job is still published: `Retract` clears the slot before it
        // reads `active`, so a job seen here stays alive until this worker leaves.
        shared.active.fetch_add(1, SeqCst);
        let slot = shared.slot.load(SeqCst);
        if !slot.is_null() {
            // SAFETY: see above.
            let job = unsafe { &*(*slot).job };
            if catch_unwind(AssertUnwindSafe(|| job(tid))).is_err() {
                shared.panicked.store(true, SeqCst);
            }
        }
        shared.active.fetch_sub(1, SeqCst);
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, SeqCst);
        for handle in &self.workers {
            handle.thread().unpark();
        }
        for handle in self.workers.drain(..) {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

    use super::*;

    #[test]
    fn every_item_runs_once_over_many_jobs() {
        let pool = Pool::new(6);
        assert_eq!(pool.threads(), 6);
        for round in 0..2000 {
            let items = 1 + round % 97;
            let next = AtomicUsize::new(0);
            let hits: Vec<AtomicUsize> = (0..items).map(|_| AtomicUsize::new(0)).collect();
            pool.run(&|tid| {
                assert!(tid < 6);
                loop {
                    let item = next.fetch_add(1, Relaxed);
                    if item >= items {
                        break;
                    }
                    hits[item].fetch_add(1, Relaxed);
                }
            });
            assert!(
                hits.iter().all(|hit| hit.load(Relaxed) == 1),
                "round {round}"
            );
        }
    }

    #[test]
    fn a_worker_panic_reaches_the_caller_and_the_pool_survives() {
        let pool = Pool::new(3);
        let worker_ran = AtomicUsize::new(0);
        let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
            pool.run(&|tid| {
                if tid != 0 {
                    worker_ran.fetch_add(1, Relaxed);
                    panic!("worker {tid}");
                }
                // Keep the caller busy until a worker has run, so one does.
                while worker_ran.load(Relaxed) == 0 {
                    std::hint::spin_loop();
                }
            })
        }));
        assert!(result.is_err());
        let count = AtomicUsize::new(0);
        pool.run(&|_| {
            count.fetch_add(1, Relaxed);
        });
        assert!(count.load(Relaxed) >= 1);
    }

    #[test]
    fn a_single_thread_pool_runs_on_the_caller() {
        let pool = Pool::new(1);
        let caller = thread::current().id();
        pool.run(&|tid| {
            assert_eq!(tid, 0);
            assert_eq!(thread::current().id(), caller);
        });
    }
}
