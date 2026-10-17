//! Persistent spin-then-park worker pool for the multi-threaded arms.
//!
//! [`Pool::run`] publishes one job (a `Fn(part)` closure) by bumping a generation word; the
//! caller executes part 0 itself and then spins until every worker has stored that generation
//! in its own cache-padded `done` slot. Idle workers spin on the generation word; after
//! `spin` without a job (or at once while the pool is [`Pool::sleep`]ing) they park on it with
//! `os_sync_wait_on_address` (macOS 14.4+ futex), and a publish that sees parked workers wakes
//! them all with one `os_sync_wake_by_address_all`. Workers run at
//! `QOS_CLASS_USER_INTERACTIVE` so the scheduler keeps them on performance cores.
//!
//! A decode brackets its jobs with [`Pool::wake`] (unpark early, so wake-up latency overlaps
//! the caller's first work) and [`Pool::sleep`] (park as soon as idle, so a finished decode
//! leaves no thread spinning on cores another measurement needs).

use std::cell::UnsafeCell;
use std::ffi::{c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::*};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn os_sync_wait_on_address(addr: *mut c_void, value: u64, size: usize, flags: u32) -> c_int;
    fn os_sync_wake_by_address_all(addr: *mut c_void, size: usize, flags: u32) -> c_int;
    fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: c_int) -> c_int;
}

const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

#[repr(align(128))]
struct Padded<T>(T);

type Call = unsafe fn(*const (), usize);

struct Inner {
    generation: Padded<AtomicU32>,
    sleepers: Padded<AtomicU32>,
    idle: Padded<AtomicBool>,
    quit: AtomicBool,
    panicked: AtomicBool,
    /// Written by the publisher before the generation bump, read by workers after it.
    job: UnsafeCell<(*const (), Option<Call>)>,
    done: Box<[Padded<AtomicU32>]>,
    spin: Duration,
}

// SAFETY: `job` is only written while no worker reads it (between a completed run and the next
// generation bump) and only read after an acquire of the bump.
unsafe impl Sync for Inner {}
unsafe impl Send for Inner {}

pub struct Pool {
    inner: Arc<Inner>,
    handles: Vec<JoinHandle<()>>,
}

impl Pool {
    /// A pool of `threads` participants: the caller plus `threads - 1` workers.
    pub fn new(threads: usize, spin: Duration) -> Pool {
        assert!(threads >= 1);
        let inner = Arc::new(Inner {
            generation: Padded(AtomicU32::new(0)),
            sleepers: Padded(AtomicU32::new(0)),
            idle: Padded(AtomicBool::new(true)),
            quit: AtomicBool::new(false),
            panicked: AtomicBool::new(false),
            job: UnsafeCell::new((std::ptr::null(), None)),
            done: (1..threads).map(|_| Padded(AtomicU32::new(0))).collect(),
            spin,
        });
        let handles = (1..threads)
            .map(|part| {
                let inner = Arc::clone(&inner);
                std::thread::Builder::new()
                    .name(format!("tdt-tail-{part}"))
                    .spawn(move || worker(&inner, part))
                    .expect("spawn tdt-tail worker")
            })
            .collect();
        Pool { inner, handles }
    }

    /// Participants, caller included.
    pub fn threads(&self) -> usize {
        self.inner.done.len() + 1
    }

    /// Leaves idle mode and unparks every parked worker (they spin until the next job).
    pub fn wake(&self) {
        self.inner.idle.0.store(false, SeqCst);
        if self.inner.sleepers.0.load(SeqCst) > 0 {
            wake_all(&self.inner.generation.0);
        }
    }

    /// Idle mode: workers park as soon as they find no job.
    pub fn sleep(&self) {
        self.inner.idle.0.store(true, SeqCst);
    }

    /// Runs `f(part)` for every `part < threads()`, part 0 on the calling thread; returns when
    /// all parts finished. Panics (after all parts finished) if a worker part panicked.
    pub fn run<F: Fn(usize) + Sync>(&self, f: &F) {
        unsafe fn call<F: Fn(usize) + Sync>(data: *const (), part: usize) {
            unsafe { (*data.cast::<F>())(part) }
        }
        let inner = &*self.inner;
        if inner.done.is_empty() {
            f(0);
            return;
        }
        // SAFETY: every worker finished the previous job (run() waited for it), so none reads.
        unsafe { *inner.job.get() = ((f as *const F).cast(), Some(call::<F>)) };
        let generation = inner.generation.0.fetch_add(1, SeqCst).wrapping_add(1);
        if inner.sleepers.0.load(SeqCst) > 0 {
            wake_all(&inner.generation.0);
        }
        let mine = catch_unwind(AssertUnwindSafe(|| f(0)));
        for d in inner.done.iter() {
            while d.0.load(Acquire) != generation {
                std::hint::spin_loop();
            }
        }
        if let Err(payload) = mine {
            std::panic::resume_unwind(payload);
        }
        if inner.panicked.swap(false, SeqCst) {
            panic!("tdt-tail worker panicked");
        }
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        self.inner.quit.store(true, SeqCst);
        self.inner.generation.0.fetch_add(1, SeqCst);
        wake_all(&self.inner.generation.0);
        for h in self.handles.drain(..) {
            let _ = h.join();
        }
    }
}

fn wake_all(word: &AtomicU32) {
    // SAFETY: a live, 4-byte aligned atomic; ENOENT (no waiter) is fine.
    unsafe {
        os_sync_wake_by_address_all(word.as_ptr().cast(), 4, 0);
    }
}

fn worker(inner: &Inner, part: usize) {
    unsafe {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
    // The generation every worker starts from is the construction value (0), not whatever it is
    // when this thread first runs: a job published before the thread started must still run.
    let mut seen = 0u32;
    loop {
        seen = wait_for_job(inner, seen);
        if inner.quit.load(Acquire) {
            return;
        }
        // SAFETY: published before the generation bump we acquired.
        let (data, call) = unsafe { *inner.job.get() };
        if let Some(call) = call {
            if catch_unwind(AssertUnwindSafe(|| unsafe { call(data, part) })).is_err() {
                inner.panicked.store(true, SeqCst);
            }
        }
        inner.done[part - 1].0.store(seen, Release);
    }
}

/// Spins until the generation moves past `seen`, parking after `inner.spin` (or immediately in
/// idle mode). Returns the new generation.
fn wait_for_job(inner: &Inner, seen: u32) -> u32 {
    let mut spins = 0u32;
    let mut started: Option<Instant> = None;
    loop {
        let g = inner.generation.0.load(Acquire);
        if g != seen {
            return g;
        }
        spins = spins.wrapping_add(1);
        if spins % 256 == 0 {
            let expired = inner.idle.0.load(Relaxed) || {
                let now = Instant::now();
                match started {
                    None => {
                        started = Some(now);
                        false
                    }
                    Some(s) => now.duration_since(s) >= inner.spin,
                }
            };
            if expired {
                inner.sleepers.0.fetch_add(1, SeqCst);
                if inner.generation.0.load(SeqCst) == seen && !inner.quit.load(SeqCst) {
                    // SAFETY: as in wake_all; returns on wake, value change or spuriously.
                    unsafe {
                        os_sync_wait_on_address(
                            inner.generation.0.as_ptr().cast(),
                            seen as u64,
                            4,
                            0,
                        );
                    }
                }
                inner.sleepers.0.fetch_sub(1, SeqCst);
                started = None;
            }
        }
        std::hint::spin_loop();
    }
}

/// `*mut T` that may cross into pool jobs; jobs write disjoint parts. Closures must go through
/// [`SyncPtr::get`] (a field access would capture the bare pointer).
#[derive(Clone, Copy)]
pub struct SyncPtr<T>(pub *mut T);
unsafe impl<T> Send for SyncPtr<T> {}
unsafe impl<T> Sync for SyncPtr<T> {}

impl<T> SyncPtr<T> {
    #[inline(always)]
    pub fn get(self) -> *mut T {
        self.0
    }
}

/// `*const T` that may cross into pool jobs.
#[derive(Clone, Copy)]
pub struct SyncConst<T>(pub *const T);
unsafe impl<T> Send for SyncConst<T> {}
unsafe impl<T> Sync for SyncConst<T> {}

impl<T> SyncConst<T> {
    #[inline(always)]
    pub fn get(self) -> *const T {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn every_part_runs_once_per_job_across_sleep_and_wake() {
        let pool = Pool::new(5, Duration::from_micros(200));
        let hits: Vec<AtomicUsize> = (0..5).map(|_| AtomicUsize::new(0)).collect();
        for round in 0..2_000 {
            if round % 500 == 0 {
                pool.sleep();
                std::thread::sleep(Duration::from_millis(2));
                pool.wake();
            }
            pool.run(&|part| {
                hits[part].fetch_add(1, Relaxed);
            });
        }
        for h in &hits {
            assert_eq!(h.load(Relaxed), 2_000);
        }
    }

    #[test]
    fn a_worker_panic_surfaces_on_the_caller() {
        let pool = Pool::new(3, Duration::from_micros(50));
        let r = catch_unwind(AssertUnwindSafe(|| {
            pool.run(&|part| {
                if part == 2 {
                    panic!("boom");
                }
            })
        }));
        assert!(r.is_err());
        pool.run(&|_| {});
    }
}
