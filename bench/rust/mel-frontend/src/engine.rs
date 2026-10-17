//! Arms and the engine that runs one of them.

use std::sync::Arc;

use crate::approx::RealFft;
use crate::exact::ExactFft;
use crate::faithful::{self, MelSum, Schedule};
use crate::frontend::Frontend;
use crate::pipeline::{Fast, Fft};
use crate::pool::Pool;

/// Threads per call for the multi-threaded arms: the sidecar's production `threadCount`
/// (`ParakeetContext` default 6), which `parakeet_full` passes to `parakeet_pcm_to_mel`.
pub const DEFAULT_THREADS: usize = 6;

/// Frames per chunk the `sparse` arm's threads claim.
const SPARSE_CHUNK: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arm {
    /// Literal port, one thread.
    Faithful,
    /// Literal port with parakeet.cpp's threading: `threads - 1` threads spawned per call.
    FaithfulSpawn,
    /// Literal port on a persistent pool, native frame slices.
    FaithfulMt,
    /// `faithful-mt` with the zero filter groups skipped and frames in dynamic chunks.
    Sparse,
    /// Fastest bit-identical arm: exact iterative NEON FFT, sparse mel, no per-call allocation,
    /// threaded z-score.
    Best,
    /// `best` with the `realfft` crate's FFT.
    RealFft,
    /// `best` with Accelerate's `vDSP_fft_zrip`.
    Vdsp,
}

/// Every name `vm_arms` advertises, in order. `best-approx` names the fastest arm overall
/// (`Arm::BEST_APPROX`).
pub const ARM_NAMES: [&str; 8] = [
    "faithful",
    "faithful-spawn",
    "faithful-mt",
    "sparse",
    "best",
    "realfft",
    "vdsp",
    "best-approx",
];

impl Arm {
    /// The arm `best-approx` runs: the fastest arm in the development smoke (README, "Timing").
    pub const BEST_APPROX: Arm = Arm::Best;

    /// An advertised arm name (an `@…` A/A replicate suffix and a `rust:` prefix are ignored).
    pub fn parse(name: &str) -> Option<Arm> {
        let name = name.strip_prefix("rust:").unwrap_or(name);
        let name = name.split('@').next().unwrap_or(name);
        Some(match name {
            "faithful" => Arm::Faithful,
            "faithful-spawn" => Arm::FaithfulSpawn,
            "faithful-mt" => Arm::FaithfulMt,
            "sparse" => Arm::Sparse,
            "best" => Arm::Best,
            "realfft" => Arm::RealFft,
            "vdsp" => Arm::Vdsp,
            "best-approx" => Arm::BEST_APPROX,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Arm::Faithful => "faithful",
            Arm::FaithfulSpawn => "faithful-spawn",
            Arm::FaithfulMt => "faithful-mt",
            Arm::Sparse => "sparse",
            Arm::Best => "best",
            Arm::RealFft => "realfft",
            Arm::Vdsp => "vdsp",
        }
    }

    /// Whether the arm is built to reproduce the native bits exactly.
    pub fn bit_identical(self) -> bool {
        !matches!(self, Arm::RealFft | Arm::Vdsp)
    }

    /// Whether the arm skips the filterbank's zero groups.
    pub fn sparse(self) -> bool {
        matches!(self, Arm::Sparse | Arm::Best | Arm::RealFft | Arm::Vdsp)
    }
}

pub struct Engine {
    fe: Arc<Frontend>,
    arm: Arm,
    imp: Imp,
}

enum Imp {
    Faithful { pool: Option<Pool>, threads: usize },
    Fast(Fast),
}

impl Engine {
    /// An engine for `arm` with `threads` threads per call (`faithful` always uses one).
    pub fn new(fe: Arc<Frontend>, arm: Arm, threads: usize) -> Result<Engine, String> {
        let threads = if arm == Arm::Faithful {
            1
        } else {
            threads.max(1)
        };
        let imp = match arm {
            Arm::Faithful | Arm::FaithfulSpawn => Imp::Faithful {
                pool: None,
                threads,
            },
            Arm::FaithfulMt | Arm::Sparse => Imp::Faithful {
                pool: (threads > 1).then(|| Pool::new(threads)),
                threads,
            },
            Arm::Best => Imp::Fast(Fast::new(&fe, Fft::Exact(ExactFft::new(&fe)), threads)?),
            Arm::RealFft => Imp::Fast(Fast::new(
                &fe,
                Fft::RealFft(RealFft::new(fe.n_fft)),
                threads,
            )?),
            Arm::Vdsp => Imp::Fast(Fast::new(&fe, Fft::Vdsp, threads)?),
        };
        Ok(Engine { fe, arm, imp })
    }

    pub fn arm(&self) -> Arm {
        self.arm
    }

    pub fn frontend(&self) -> &Frontend {
        &self.fe
    }

    /// Threads one call uses.
    pub fn threads(&self) -> usize {
        match &self.imp {
            Imp::Faithful { threads, .. } => *threads,
            Imp::Fast(fast) => fast.threads(),
        }
    }

    /// 4-bin filter groups each frame evaluates.
    pub fn groups_per_frame(&self) -> usize {
        if self.arm.sparse() {
            self.fe.sparse.kept_groups()
        } else {
            self.fe.sparse.dense_groups
        }
    }

    /// The frontend of `samples` into `out` as frame-major `[n_frames][n_mels]`. Returns
    /// `n_frames`, or an error (nothing written) when `out` is too small.
    pub fn compute(&mut self, samples: &[f32], out: &mut [f32]) -> Result<usize, String> {
        let n_frames = self.fe.n_frames(samples.len());
        let needed = n_frames * self.fe.n_mels;
        if out.len() < needed {
            return Err(format!(
                "output holds {} values; {} samples need {n_frames} frames x {} mels",
                out.len(),
                samples.len(),
                self.fe.n_mels
            ));
        }
        let fe = &*self.fe;
        let written = match &mut self.imp {
            Imp::Faithful { pool, threads } => {
                let schedule = match (self.arm, pool.as_ref()) {
                    (Arm::FaithfulSpawn, _) if *threads > 1 => Schedule::Spawn(*threads),
                    (Arm::FaithfulMt, Some(pool)) => Schedule::PoolSlices(pool),
                    (Arm::Sparse, Some(pool)) => Schedule::PoolChunks(pool, SPARSE_CHUNK),
                    _ => Schedule::Single,
                };
                let mel = if self.arm == Arm::Sparse {
                    MelSum::Sparse
                } else {
                    MelSum::Dense
                };
                faithful::log_mel(fe, samples, out, schedule, mel)
            }
            Imp::Fast(fast) => fast.compute(fe, samples, out),
        };
        debug_assert_eq!(written, n_frames);
        Ok(n_frames)
    }
}
