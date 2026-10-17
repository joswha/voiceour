//! Modern real FFTs for the approximate arms: `realfft` (rustfft) and Accelerate's vDSP. Their
//! butterflies differ from parakeet.cpp's, so the power spectrum differs in the last bits; the
//! mel sum, log and z-score after it are the exact arms' code.

use std::arch::aarch64::*;
use std::ffi::{c_int, c_long, c_ulong, c_void};
use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

/// `realfft` forward plan shared by the threads, plus one thread's buffers.
pub(crate) struct RealFft {
    plan: Arc<dyn RealToComplex<f32>>,
}

pub(crate) struct RealFftScratch {
    input: Vec<f32>,
    output: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
}

impl RealFft {
    pub(crate) fn new(n_fft: usize) -> RealFft {
        RealFft {
            plan: RealFftPlanner::<f32>::new().plan_fft_forward(n_fft),
        }
    }

    pub(crate) fn scratch(&self) -> RealFftScratch {
        RealFftScratch {
            input: self.plan.make_input_vec(),
            output: self.plan.make_output_vec(),
            scratch: self.plan.make_scratch_vec(),
        }
    }

    /// `power[k] = fmadd(re, re, im*im)` of the unnormalized forward DFT, `k in 0..=n/2`.
    pub(crate) fn power(&self, frame: &[f32], scratch: &mut RealFftScratch, power: &mut [f32]) {
        let n = scratch.input.len();
        scratch.input.copy_from_slice(&frame[..n]);
        self.plan
            .process_with_scratch(
                &mut scratch.input,
                &mut scratch.output,
                &mut scratch.scratch,
            )
            .expect("realfft buffers sized by the plan");
        for (p, bin) in power.iter_mut().zip(&scratch.output) {
            *p = bin.re.mul_add(bin.re, bin.im * bin.im);
        }
    }
}

#[repr(C)]
struct DSPSplitComplex {
    realp: *mut f32,
    imagp: *mut f32,
}

const FFT_RADIX2: c_int = 0;
const FFT_FORWARD: c_int = 1;

#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn vDSP_create_fftsetup(log2n: c_ulong, radix: c_int) -> *mut c_void;
    fn vDSP_destroy_fftsetup(setup: *mut c_void);
    fn vDSP_fft_zrip(
        setup: *mut c_void,
        c: *const DSPSplitComplex,
        stride: c_long,
        log2n: c_ulong,
        direction: c_int,
    );
}

/// 64 bytes of floats. `vDSP_fft_zrip` rounds differently when its split buffers are not 64-byte
/// aligned (a probe on macOS 27: 423 of 512 output floats changed at every offset of 4 to 48
/// bytes), so `malloc`'s 16-byte alignment made this arm's output depend on which thread's
/// buffers a frame landed in. Fixed 64-byte buffers keep it deterministic.
#[derive(Clone, Copy)]
#[repr(C, align(64))]
struct Aligned([f32; 16]);

/// One thread's vDSP setup and split-complex buffers (a setup per thread keeps the arm free of
/// any cross-thread sharing assumption).
pub(crate) struct VdspScratch {
    setup: *mut c_void,
    log2n: c_ulong,
    half: usize,
    realp: Vec<Aligned>,
    imagp: Vec<Aligned>,
}

// SAFETY: the setup is only used by the thread that holds the scratch at that moment.
unsafe impl Send for VdspScratch {}

impl VdspScratch {
    pub(crate) fn new(n_fft: usize) -> Result<VdspScratch, String> {
        let log2n = n_fft.trailing_zeros() as c_ulong;
        // SAFETY: plain constructor call; null is checked.
        let setup = unsafe { vDSP_create_fftsetup(log2n, FFT_RADIX2) };
        if setup.is_null() {
            return Err(format!("vDSP_create_fftsetup({log2n}) failed"));
        }
        let half = n_fft / 2;
        let blocks = half.div_ceil(16);
        Ok(VdspScratch {
            setup,
            log2n,
            half,
            realp: vec![Aligned([0.0; 16]); blocks],
            imagp: vec![Aligned([0.0; 16]); blocks],
        })
    }

    /// `vDSP_fft_zrip` of the real frame, packed as even/odd samples. Its forward result is twice
    /// the DFT, with DC in `realp[0]` and Nyquist in `imagp[0]`; the exact halving is applied
    /// before the same `fmadd(re, re, im*im)` power.
    pub(crate) fn power(&mut self, frame: &[f32], power: &mut [f32]) {
        let half = self.half;
        assert!(frame.len() >= 2 * half && power.len() > half && half % 4 == 0);
        let re = self.realp.as_mut_ptr().cast::<f32>();
        let im = self.imagp.as_mut_ptr().cast::<f32>();
        // SAFETY: `frame` holds `2 * half` floats, `realp`/`imagp` at least `half` each.
        let (realp, imagp) = unsafe {
            let src = frame.as_ptr();
            let mut m = 0;
            while m < half {
                let pair = vld2q_f32(src.add(2 * m));
                vst1q_f32(re.add(m), pair.0);
                vst1q_f32(im.add(m), pair.1);
                m += 4;
            }
            let split = DSPSplitComplex {
                realp: re,
                imagp: im,
            };
            vDSP_fft_zrip(self.setup, &split, 1, self.log2n, FFT_FORWARD);
            (
                std::slice::from_raw_parts(re, half),
                std::slice::from_raw_parts(im, half),
            )
        };
        let dc = 0.5 * realp[0];
        let nyquist = 0.5 * imagp[0];
        power[0] = dc * dc;
        power[half] = nyquist * nyquist;
        for k in 1..half {
            let re = 0.5 * realp[k];
            let im = 0.5 * imagp[k];
            power[k] = re.mul_add(re, im * im);
        }
    }
}

impl Drop for VdspScratch {
    fn drop(&mut self) {
        // SAFETY: created by `vDSP_create_fftsetup`, destroyed once.
        unsafe { vDSP_destroy_fftsetup(self.setup) };
    }
}
