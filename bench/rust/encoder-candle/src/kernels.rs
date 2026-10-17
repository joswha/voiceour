//! The crate's custom Metal kernels (`kernels.metal`) wrapped as candle custom ops.
//!
//! Every op runs on the device's shared compute encoder through candle's own
//! `command_encoder()`, so candle's buffer hazard tracking orders it against the stock ops.

use std::collections::HashMap;

use candle_core::backend::BackendStorage;
use candle_core::{
    CpuStorage, CustomOp1, CustomOp2, CustomOp3, DType, Layout, MetalDevice, MetalStorage, Result,
    Shape, Tensor, bail,
};
use candle_metal_kernels::metal::{Buffer, ComputeCommandEncoder, ComputePipeline};
use candle_metal_kernels::{Output, SdpaDType, set_params};
use objc2_metal::{MTLCompileOptions, MTLLanguageVersion, MTLSize};

const SOURCE: &str = include_str!("kernels.metal");

const KERNELS: [&str; 7] = [
    "sub_conv0",
    "sub_dw_s2",
    "dwconv9",
    "glu_dwconv9_bn_silu",
    "add_ln",
    "split_qkv",
    "rel_shift",
];

/// Overrides the Metal Shading Language version of every library the engine compiles: this
/// file's `kernels.metal` and, through `patches/candle-metal-kernels-0.11.0-msl-language-version.patch`
/// (same variable, same default), candle's own. Accepts 3.0, 3.1, 3.2 or 4.0.
const LANGUAGE_VERSION_ENV: &str = "CANDLE_METAL_LANGUAGE_VERSION";

/// The pinned Metal Shading Language version, 3.2 (macOS 15) unless `LANGUAGE_VERSION_ENV` says
/// otherwise. Left unset, the version is Metal's default for the host process rather than a
/// choice of this crate (README.md, "Metal toolchain").
fn language_version() -> Result<MTLLanguageVersion> {
    match std::env::var(LANGUAGE_VERSION_ENV).as_deref() {
        Err(_) | Ok("3.2") => Ok(MTLLanguageVersion::Version3_2),
        Ok("3.1") => Ok(MTLLanguageVersion::Version3_1),
        Ok("3.0") => Ok(MTLLanguageVersion::Version3_0),
        Ok("4.0") => Ok(MTLLanguageVersion::Version4_0),
        Ok(other) => bail!("{LANGUAGE_VERSION_ENV}={other:?}: expected 3.0, 3.1, 3.2 or 4.0"),
    }
}

/// Compiled pipelines, keyed by `<kernel>_<f32|f16|bf16>`.
pub struct Kernels {
    pipelines: HashMap<String, ComputePipeline>,
}

impl Kernels {
    pub fn new(device: &MetalDevice) -> Result<Kernels> {
        let raw = device.device();
        // Explicit options, so this library's language version and math mode do not depend on
        // the host binary: the pinned language version, and fast math (math mode and
        // floating-point functions both fast, the set candle gives its own libraries).
        let options = MTLCompileOptions::new();
        options.setLanguageVersion(language_version()?);
        #[allow(deprecated)]
        options.setFastMathEnabled(true);
        let library = raw
            .new_library_with_source(SOURCE, Some(&options))
            .map_err(candle_core::Error::wrap)?;
        let mut pipelines = HashMap::new();
        for base in KERNELS {
            for suffix in ["f32", "f16", "bf16"] {
                let name = format!("{base}_{suffix}");
                let function = library
                    .get_function(&name, None)
                    .map_err(candle_core::Error::wrap)?;
                let pipeline = raw
                    .new_compute_pipeline_state_with_function(&function)
                    .map_err(candle_core::Error::wrap)?;
                pipelines.insert(name, pipeline);
            }
        }
        Ok(Kernels { pipelines })
    }

    fn get(&self, base: &str, dtype: DType) -> Result<ComputePipeline> {
        let suffix = match dtype {
            DType::F32 => "f32",
            DType::F16 => "f16",
            DType::BF16 => "bf16",
            other => bail!("no {base} kernel for {other:?}"),
        };
        match self.pipelines.get(&format!("{base}_{suffix}")) {
            Some(pipeline) => Ok(pipeline.clone()),
            None => bail!("kernel {base}_{suffix} not compiled"),
        }
    }

    /// conv.0 + bias + ReLU: mel `[n_t, n_f]` f32 → `[C, ceil(n_t/2), ceil(n_f/2)]` in `dtype`.
    pub fn sub_conv0(&self, mel: &Tensor, w: &Tensor, b: &Tensor, dtype: DType) -> Result<Tensor> {
        let (n_t, n_f) = mel.dims2()?;
        let (c, _) = w.dims2()?;
        let op = SubConv0 {
            pipeline: self.get("sub_conv0", dtype)?,
            dims: [n_t, n_f, n_t.div_ceil(2), n_f.div_ceil(2)],
            c,
            dtype,
        };
        mel.apply_op3_no_bwd(w, b, &op)
    }

    /// Depthwise 3x3 / stride 2 / pad 1 + bias: `[C, h, w]` → `[C, ceil(h/2), ceil(w/2)]`.
    pub fn sub_dw_s2(&self, x: &Tensor, w: &Tensor, b: &Tensor) -> Result<Tensor> {
        let op = SubDwS2 {
            pipeline: self.get("sub_dw_s2", x.dtype())?,
        };
        x.apply_op3_no_bwd(w, b, &op)
    }

    /// Depthwise conv over time, K = 9: `[n_t, C]` → `[n_t, C]`.
    pub fn dwconv9(&self, x: &Tensor, w: &Tensor) -> Result<Tensor> {
        let op = DwConv9 {
            pipeline: self.get("dwconv9", x.dtype())?,
        };
        x.apply_op2_no_bwd(w, &op)
    }

    /// GLU + depthwise conv + BatchNorm + SiLU: pw1 `[n_t, 2C]` → `[n_t, C]`.
    pub fn glu_dwconv9_bn_silu(&self, pw1: &Tensor, w: &Tensor, bn: &Tensor) -> Result<Tensor> {
        let op = GluDwBnSilu {
            pipeline: self.get("glu_dwconv9_bn_silu", pw1.dtype())?,
        };
        pw1.apply_op3_no_bwd(w, bn, &op)
    }

    /// `r = x + alpha * h; y = LN(r)`. Returns `(Some(r), y)` when `keep_residual`, else
    /// `(None, y)`. `y` is plane 0 of the output so it starts at buffer offset 0, which
    /// candle's quantized matmul requires of its input.
    pub fn add_ln(
        &self,
        x: &Tensor,
        h: &Tensor,
        alpha: f32,
        ln: &Tensor,
        keep_residual: bool,
    ) -> Result<(Option<Tensor>, Tensor)> {
        let op = AddLn {
            pipeline: self.get("add_ln", x.dtype())?,
            alpha,
            has_h: true,
            keep_residual,
        };
        let out = x.apply_op3_no_bwd(h, ln, &op)?;
        if keep_residual {
            Ok((Some(out.get(1)?), out.get(0)?))
        } else {
            Ok((None, out))
        }
    }

    /// `y = LN(x)`.
    pub fn ln(&self, x: &Tensor, ln: &Tensor) -> Result<Tensor> {
        let op = AddLn {
            pipeline: self.get("add_ln", x.dtype())?,
            alpha: 0.0,
            has_h: false,
            keep_residual: false,
        };
        x.apply_op3_no_bwd(x, ln, &op)
    }

    /// Q/K/V split: qkv `[n_t, 3·H·D]` → `(q_u, q_v)`, each `[H, n_t, D]`, with
    /// `q_v` pre-multiplied by `scale`.
    pub fn split_qkv(
        &self,
        qkv: &Tensor,
        uv: &Tensor,
        n_head: usize,
        d_head: usize,
        scale: f32,
    ) -> Result<(Tensor, Tensor)> {
        let op = SplitQkv {
            pipeline: self.get("split_qkv", qkv.dtype())?,
            n_head,
            d_head,
            scale,
        };
        let out = qkv.apply_op2_no_bwd(uv, &op)?;
        Ok((out.get(0)?, out.get(1)?))
    }

    /// Relative shift as a gather: bd `[H, n_t, 2n_t-1]` → `[H, n_t, n_t]`.
    pub fn rel_shift(&self, bd: &Tensor) -> Result<Tensor> {
        let op = RelShift {
            pipeline: self.get("rel_shift", bd.dtype())?,
        };
        bd.apply_op1_no_bwd(&op)
    }
}

fn metal_only<T>(name: &str) -> Result<T> {
    bail!("{name}: the encoder-candle custom ops run on Metal only")
}

fn contiguous(name: &str, layout: &Layout) -> Result<()> {
    if layout.is_contiguous() {
        Ok(())
    } else {
        bail!("{name}: input must be contiguous, got {layout:?}")
    }
}

fn input<'a>(storage: &'a MetalStorage, layout: &Layout) -> (&'a Buffer, usize) {
    (
        storage.buffer(),
        layout.start_offset() * storage.dtype().size_in_bytes(),
    )
}

fn size(width: usize, height: usize, depth: usize) -> MTLSize {
    MTLSize {
        width,
        height,
        depth,
    }
}

fn i32s<const N: usize>(values: [usize; N]) -> [i32; N] {
    values.map(|v| v as i32)
}

struct SubConv0 {
    pipeline: ComputePipeline,
    dims: [usize; 4],
    c: usize,
    dtype: DType,
}

impl CustomOp3 for SubConv0 {
    fn name(&self) -> &'static str {
        "sub_conv0"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        mel: &MetalStorage,
        mel_l: &Layout,
        w: &MetalStorage,
        w_l: &Layout,
        b: &MetalStorage,
        b_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [mel_l, w_l, b_l] {
            contiguous(self.name(), l)?;
        }
        let [_, _, oh, ow] = self.dims;
        let count = self.c * oh * ow;
        let device = mel.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, self.dtype)
            .with_label("sub_conv0")
            .build()?;
        let params = i32s(self.dims);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (
                input(mel, mel_l),
                input(w, w_l),
                input(b, b_l),
                Output::new(&out),
                &params[..]
            )
        );
        encoder.dispatch_threads(size(ow, oh, self.c), size(ow.min(64), 4, 1));
        Ok((
            MetalStorage::new(out, device.clone(), count, self.dtype),
            Shape::from((self.c, oh, ow)),
        ))
    }
}

struct SubDwS2 {
    pipeline: ComputePipeline,
}

impl CustomOp3 for SubDwS2 {
    fn name(&self) -> &'static str {
        "sub_dw_s2"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        x: &MetalStorage,
        x_l: &Layout,
        w: &MetalStorage,
        w_l: &Layout,
        b: &MetalStorage,
        b_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [x_l, w_l, b_l] {
            contiguous(self.name(), l)?;
        }
        let (c, h, wd) = x_l.shape().dims3()?;
        let (oh, ow) = (h.div_ceil(2), wd.div_ceil(2));
        let count = c * oh * ow;
        let dtype = x.dtype();
        let device = x.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("sub_dw_s2")
            .build()?;
        let params = i32s([h, wd, oh, ow]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (
                input(x, x_l),
                input(w, w_l),
                input(b, b_l),
                Output::new(&out),
                &params[..]
            )
        );
        encoder.dispatch_threads(
            size(ow, oh, c),
            size(ow.min(64), (256 / ow.min(64)).max(1), 1),
        );
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((c, oh, ow)),
        ))
    }
}

struct DwConv9 {
    pipeline: ComputePipeline,
}

impl CustomOp2 for DwConv9 {
    fn name(&self) -> &'static str {
        "dwconv9"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        x: &MetalStorage,
        x_l: &Layout,
        w: &MetalStorage,
        w_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [x_l, w_l] {
            contiguous(self.name(), l)?;
        }
        let (n_t, c) = x_l.shape().dims2()?;
        let count = n_t * c;
        let dtype = x.dtype();
        let device = x.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("dwconv9")
            .build()?;
        let params = i32s([n_t, c]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (input(x, x_l), input(w, w_l), Output::new(&out), &params[..])
        );
        encoder.dispatch_threads(size(c, n_t, 1), size(256, 1, 1));
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((n_t, c)),
        ))
    }
}

struct GluDwBnSilu {
    pipeline: ComputePipeline,
}

impl CustomOp3 for GluDwBnSilu {
    fn name(&self) -> &'static str {
        "glu_dwconv9_bn_silu"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        pw1: &MetalStorage,
        pw1_l: &Layout,
        w: &MetalStorage,
        w_l: &Layout,
        bn: &MetalStorage,
        bn_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [pw1_l, w_l, bn_l] {
            contiguous(self.name(), l)?;
        }
        let (n_t, c2) = pw1_l.shape().dims2()?;
        let c = c2 / 2;
        let count = n_t * c;
        let dtype = pw1.dtype();
        let device = pw1.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("glu_dwconv9_bn_silu")
            .build()?;
        let params = i32s([n_t, c]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (
                input(pw1, pw1_l),
                input(w, w_l),
                input(bn, bn_l),
                Output::new(&out),
                &params[..]
            )
        );
        encoder.dispatch_threads(size(c, n_t, 1), size(256, 1, 1));
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((n_t, c)),
        ))
    }
}

/// Threads per LayerNorm threadgroup; must match `LN_THREADS` in kernels.metal.
const LN_THREADS: usize = 256;
/// The fused LayerNorm handles exactly this row width (4 values per thread).
pub const LN_WIDTH: usize = 4 * LN_THREADS;

struct AddLn {
    pipeline: ComputePipeline,
    alpha: f32,
    has_h: bool,
    keep_residual: bool,
}

impl CustomOp3 for AddLn {
    fn name(&self) -> &'static str {
        "add_ln"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        x: &MetalStorage,
        x_l: &Layout,
        h: &MetalStorage,
        h_l: &Layout,
        ln: &MetalStorage,
        ln_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [x_l, h_l, ln_l] {
            contiguous(self.name(), l)?;
        }
        let (n_t, n) = x_l.shape().dims2()?;
        if n != LN_WIDTH || h_l.shape().dims2()? != (n_t, n) {
            bail!(
                "add_ln: rows must be {LN_WIDTH} wide, got x {:?} h {:?}",
                x_l.dims(),
                h_l.dims()
            );
        }
        let planes = if self.keep_residual { 2 } else { 1 };
        let count = planes * n_t * n;
        let dtype = x.dtype();
        let device = x.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("add_ln")
            .build()?;
        // Plane 0: y; plane 1 (kept residual): r.
        let r_offset = (planes - 1) * n_t * n * dtype.size_in_bytes();
        let params = i32s([n, usize::from(self.has_h), usize::from(self.keep_residual)]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (
                input(x, x_l),
                input(h, h_l),
                input(ln, ln_l),
                Output::with_offset(&out, r_offset),
                Output::new(&out),
                &params[..],
                self.alpha
            )
        );
        encoder.dispatch_thread_groups(size(n_t, 1, 1), size(LN_THREADS, 1, 1));
        let shape = if self.keep_residual {
            Shape::from((2, n_t, n))
        } else {
            Shape::from((n_t, n))
        };
        Ok((MetalStorage::new(out, device.clone(), count, dtype), shape))
    }
}

struct SplitQkv {
    pipeline: ComputePipeline,
    n_head: usize,
    d_head: usize,
    scale: f32,
}

impl CustomOp2 for SplitQkv {
    fn name(&self) -> &'static str {
        "split_qkv"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        qkv: &MetalStorage,
        qkv_l: &Layout,
        uv: &MetalStorage,
        uv_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        for l in [qkv_l, uv_l] {
            contiguous(self.name(), l)?;
        }
        let (n_t, width) = qkv_l.shape().dims2()?;
        let (h, d) = (self.n_head, self.d_head);
        if width != 3 * h * d {
            bail!("split_qkv: expected {} columns, got {width}", 3 * h * d);
        }
        let count = 2 * h * n_t * d;
        let dtype = qkv.dtype();
        let device = qkv.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("split_qkv")
            .build()?;
        let q_v_offset = h * n_t * d * dtype.size_in_bytes();
        let params = i32s([n_t, h, d]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(
            encoder,
            (
                input(qkv, qkv_l),
                input(uv, uv_l),
                Output::new(&out),
                Output::with_offset(&out, q_v_offset),
                &params[..],
                self.scale
            )
        );
        encoder.dispatch_threads(
            size(d, h, n_t),
            size(d.min(256), (256 / d.min(256)).max(1), 1),
        );
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((2, h, n_t, d)),
        ))
    }
}

struct RelShift {
    pipeline: ComputePipeline,
}

impl CustomOp1 for RelShift {
    fn name(&self) -> &'static str {
        "rel_shift"
    }

    fn cpu_fwd(&self, _: &CpuStorage, _: &Layout) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(&self, bd: &MetalStorage, bd_l: &Layout) -> Result<(MetalStorage, Shape)> {
        contiguous(self.name(), bd_l)?;
        let (h, n_t, w) = bd_l.shape().dims3()?;
        if w != 2 * n_t - 1 {
            bail!("rel_shift: expected {} positions, got {w}", 2 * n_t - 1);
        }
        let count = h * n_t * n_t;
        let dtype = bd.dtype();
        let device = bd.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("rel_shift")
            .build()?;
        let params = i32s([n_t]);
        let guard = device.command_encoder()?;
        let encoder: &ComputeCommandEncoder = guard.as_ref();
        encoder.set_compute_pipeline_state(&self.pipeline);
        set_params!(encoder, (input(bd, bd_l), Output::new(&out), &params[..]));
        encoder.dispatch_threads(size(n_t, n_t, h), size(n_t.min(64), 4, 1));
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((h, n_t, n_t)),
        ))
    }
}

/// MLX steel attention (`candle_nn::ops::sdpa`'s full kernel) with an additive mask, writing
/// the output straight into the frame-major `[n_t, H·D]` layout the output projection takes.
/// `q`: `[1, H, n_t, D]`, `k` / `v`: `[1, H, n_t, D]` views (any batch/head/seq strides, unit
/// lane stride), `mask`: contiguous `[1, H, n_t, n_t]`, already scaled like the scores.
pub struct SdpaFrameMajor {
    pub mask: Tensor,
    pub scale: f32,
}

impl CustomOp3 for SdpaFrameMajor {
    fn name(&self) -> &'static str {
        "sdpa_frame_major"
    }

    fn cpu_fwd(
        &self,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
        _: &CpuStorage,
        _: &Layout,
    ) -> Result<(CpuStorage, Shape)> {
        metal_only(self.name())
    }

    fn metal_fwd(
        &self,
        q: &MetalStorage,
        q_l: &Layout,
        k: &MetalStorage,
        k_l: &Layout,
        v: &MetalStorage,
        v_l: &Layout,
    ) -> Result<(MetalStorage, Shape)> {
        let (b, h, n_t, d) = q_l.shape().dims4()?;
        if b != 1 || k_l.dims() != q_l.dims() || v_l.dims() != q_l.dims() {
            bail!(
                "sdpa_frame_major: q {:?} k {:?} v {:?}",
                q_l.dims(),
                k_l.dims(),
                v_l.dims()
            );
        }
        for (name, l) in [("q", q_l), ("k", k_l), ("v", v_l)] {
            if l.stride()[3] != 1 {
                bail!(
                    "sdpa_frame_major: {name} lanes must be contiguous, got {:?}",
                    l.stride()
                );
            }
        }
        let (mask_storage, mask_l) = self.mask.storage_and_layout();
        let mask_storage = match &*mask_storage {
            candle_core::Storage::Metal(m) => m,
            _ => bail!("sdpa_frame_major: mask must live on the Metal device"),
        };
        if mask_l.dims() != [1, h, n_t, n_t]
            || !mask_l.is_contiguous()
            || mask_l.start_offset() != 0
        {
            bail!(
                "sdpa_frame_major: mask must be a contiguous [1, {h}, {n_t}, {n_t}], got {mask_l:?}"
            );
        }
        let dtype = q.dtype();
        if k.dtype() != dtype || v.dtype() != dtype || mask_storage.dtype() != dtype {
            bail!("sdpa_frame_major: q, k, v and mask must share one dtype");
        }
        let itype = match dtype {
            DType::F32 => SdpaDType::F32,
            DType::F16 => SdpaDType::F16,
            DType::BF16 => SdpaDType::BF16,
            other => bail!("sdpa_frame_major: unsupported dtype {other:?}"),
        };
        let count = n_t * h * d;
        let device = q.device();
        let out = device
            .new_buffer_builder()
            .with_size_for(count, dtype)
            .with_label("sdpa_frame_major")
            .build()?;
        // Batch, head, sequence strides of the [n_t][H][D] output.
        let o_strides = [count, d, h * d, 1];
        let guard = device.command_encoder()?;
        candle_metal_kernels::call_sdpa_full(
            device.device(),
            &guard,
            device.kernels(),
            q_l.start_offset() * dtype.size_in_bytes(),
            q_l.dims(),
            q_l.stride(),
            q.buffer(),
            k_l.start_offset() * dtype.size_in_bytes(),
            k_l.dims(),
            k_l.stride(),
            k.buffer(),
            v_l.start_offset() * dtype.size_in_bytes(),
            v.buffer(),
            v_l.stride(),
            Some(itype),
            Some(mask_storage.buffer()),
            Some(mask_l.stride()),
            &out,
            &o_strides,
            self.scale,
            false,
            itype,
        )
        .map_err(candle_core::Error::wrap)?;
        Ok((
            MetalStorage::new(out, device.clone(), count, dtype),
            Shape::from((n_t, h * d)),
        ))
    }
}
