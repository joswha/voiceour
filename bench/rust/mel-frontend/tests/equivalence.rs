//! Arm equivalence on synthetic signals, the C ABI, and (when present) the native dumps.
//!
//! Tests that need the pinned model or the dumps skip themselves with a note on stderr when those
//! files are absent.

use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};

use mel_frontend::{
    ARM_NAMES, Arm, Engine, Frontend, vm_abi_version, vm_arms, vm_compute, vm_engine_free,
    vm_engine_new, wav,
};
use parakeet_model::pin;

/// The pinned model's frontend, opened once for every test (None, with a note, when absent).
static FRONTEND: LazyLock<Option<Arc<Frontend>>> = LazyLock::new(|| {
    let path = pin::default_model_path();
    if !path.is_file() {
        eprintln!("skipping: no pinned model at {}", path.display());
        return None;
    }
    Some(Arc::new(Frontend::open(&path).expect("open pinned model")))
});

fn frontend() -> Option<Arc<Frontend>> {
    FRONTEND.clone()
}

fn run(engine: &mut Engine, samples: &[f32]) -> Vec<f32> {
    let fe = engine.frontend();
    let mut out = vec![f32::NAN; fe.n_frames(samples.len()) * fe.n_mels];
    let frames = engine.compute(samples, &mut out).expect("compute");
    assert_eq!(frames, samples.len() / 160 + 1);
    out
}

fn bits(values: &[f32]) -> Vec<u32> {
    values.iter().map(|v| v.to_bits()).collect()
}

/// Deterministic test audio.
fn noise(n: usize, seed: u32, amplitude: f32) -> Vec<f32> {
    let mut state = seed;
    (0..n)
        .map(|_| {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            ((state >> 8) as f32 / (1u32 << 24) as f32 - 0.5) * 2.0 * amplitude
        })
        .collect()
}

fn signals() -> Vec<(String, Vec<f32>)> {
    let mut signals = Vec::new();
    for n in [
        0usize, 1, 2, 159, 160, 161, 319, 320, 399, 400, 401, 511, 512, 513, 1000, 4000,
    ] {
        signals.push((format!("noise {n}"), noise(n, n as u32 + 1, 0.3)));
    }
    signals.push(("silence 1 s".into(), vec![0.0; 16_000]));
    let mut impulse = vec![0.0; 16_000];
    impulse[8_000] = 1.0;
    signals.push(("impulse".into(), impulse));
    signals.push((
        "full-scale square".into(),
        (0..32_000)
            .map(|i| {
                if (i / 40) % 2 == 0 {
                    32767.0 / 32768.0
                } else {
                    -1.0
                }
            })
            .collect(),
    ));
    signals.push((
        "int16 quantized noise 3.3 s".into(),
        noise(52_800, 99, 0.5)
            .into_iter()
            .map(|v| (v * 32768.0).round().clamp(-32768.0, 32767.0) / 32768.0)
            .collect(),
    ));
    signals.push(("tiny values".into(), noise(16_000, 5, 1e-30)));
    let mut with_inf = noise(16_000, 6, 0.3);
    with_inf[7_777] = f32::INFINITY;
    signals.push(("one +inf sample".into(), with_inf));
    let mut with_nan = noise(16_000, 7, 0.3);
    with_nan[123] = f32::NAN;
    signals.push(("one NaN sample".into(), with_nan));
    signals.push(("huge values".into(), noise(16_000, 8, 1e30)));
    signals
}

#[test]
fn abi_version_and_arm_list() {
    assert_eq!(vm_abi_version(), 1);
    // SAFETY: a static NUL-terminated string.
    let listed = unsafe { CStr::from_ptr(vm_arms()) }.to_str().unwrap();
    assert_eq!(listed.split(',').collect::<Vec<_>>(), ARM_NAMES);
    for name in ARM_NAMES {
        assert!(Arm::parse(name).is_some(), "{name}");
    }
    assert_eq!(Arm::parse("rust:best@aa"), Some(Arm::Best));
    assert_eq!(Arm::parse("nope"), None);
}

#[test]
fn sparse_groups_hold_every_nonzero_weight() {
    let Some(fe) = frontend() else { return };
    let sparse = &fe.sparse;
    let mut kept = 0;
    for j in 0..fe.n_mels {
        let row = &fe.filters[j * fe.n_fb..(j + 1) * fe.n_fb];
        let mut covered = vec![false; fe.n_fb];
        let (first, end) = sparse.group_range[j];
        for g in first as usize..end as usize {
            let k = sparse.group_k[g] as usize;
            assert_eq!(
                sparse.group_w[g],
                [row[k], row[k + 1], row[k + 2], row[k + 3]]
            );
            covered[k..k + 4].iter_mut().for_each(|c| *c = true);
        }
        let (first, end) = sparse.tail_range[j];
        for t in first as usize..end as usize {
            covered[sparse.tail_k[t] as usize] = true;
        }
        for (k, &w) in row.iter().enumerate() {
            assert!(w == 0.0 || covered[k], "mel {j} bin {k} weight {w} dropped");
        }
        kept += (end - first) as usize;
    }
    // The pinned file: 504 non-zero weights in 225 of the 8192 dense groups, none in bin 256.
    assert_eq!(
        (sparse.kept_groups(), kept, sparse.dense_groups),
        (225, 0, 8192)
    );
    assert_eq!(fe.filters.iter().filter(|w| **w != 0.0).count(), 504);
}

/// Every exact arm against `faithful` (the literal port), at several thread counts and twice per
/// engine. Finite values must match bit for bit. A NaN must be a NaN, but its sign may differ:
/// LLVM picks which multiplicand of `a - b*c` the `fmsub`/`fmls` instruction negates (the IR
/// leaves NaN signs unspecified), and NaN operands keep the sign that negation gave them. Only
/// non-finite input produces NaN past the z-score, which the int16 sidecar input cannot.
#[test]
fn exact_arms_match_faithful_bit_for_bit() {
    let Some(fe) = frontend() else { return };
    let mut faithful = Engine::new(Arc::clone(&fe), Arm::Faithful, 1).unwrap();
    let mut others: Vec<Engine> = Vec::new();
    for arm in [Arm::FaithfulSpawn, Arm::FaithfulMt, Arm::Sparse, Arm::Best] {
        for threads in [1, 3, 6] {
            others.push(Engine::new(Arc::clone(&fe), arm, threads).unwrap());
        }
    }
    let same =
        |a: u32, b: u32| a == b || (f32::from_bits(a).is_nan() && f32::from_bits(b).is_nan());
    for (name, samples) in signals() {
        let reference = bits(&run(&mut faithful, &samples));
        let finite_input = samples.iter().all(|v| v.is_finite() && v.abs() <= 1.0);
        for engine in &mut others {
            for repeat in 0..2 {
                let got = bits(&run(engine, &samples));
                let differing = got
                    .iter()
                    .zip(&reference)
                    .filter(|&(&a, &b)| !same(a, b))
                    .count();
                let nan_sign = got
                    .iter()
                    .zip(&reference)
                    .filter(|&(&a, &b)| a != b && same(a, b))
                    .count();
                assert!(
                    differing == 0 && (nan_sign == 0 || !finite_input),
                    "{name}: {} x{} (repeat {repeat}) differs from faithful in {differing} values \
                     (+{nan_sign} NaN signs)",
                    engine.arm().name(),
                    engine.threads()
                );
            }
        }
    }
}

#[test]
fn non_finite_input_follows_the_native_nan_rules() {
    let Some(fe) = frontend() else { return };
    let mut best = Engine::new(Arc::clone(&fe), Arm::Best, 6).unwrap();
    let mut samples = noise(16_000, 11, 0.3);
    samples[8_000] = f32::INFINITY;
    let out = run(&mut best, &samples);
    // The frames whose window covers the inf sample are NaN in every bin (dense `inf * 0`), and
    // the z-score then spreads NaN through every frame of every bin.
    assert!(out.iter().all(|v| v.is_nan()));
}

#[test]
fn approximate_arms_stay_close() {
    let Some(fe) = frontend() else { return };
    let mut faithful = Engine::new(Arc::clone(&fe), Arm::Faithful, 1).unwrap();
    for arm in [Arm::RealFft, Arm::Vdsp] {
        let mut engine = Engine::new(Arc::clone(&fe), arm, 6).unwrap();
        for seed in 0..3 {
            let samples = noise(48_000, 1_000 + seed, 0.3);
            let reference = run(&mut faithful, &samples);
            let got = run(&mut engine, &samples);
            let max_abs = got
                .iter()
                .zip(&reference)
                .map(|(a, b)| (a - b).abs())
                .fold(0.0f32, f32::max);
            assert!(max_abs < 1e-3, "{}: max_abs {max_abs}", arm.name());
            // Deterministic across calls, whichever threads take which frames.
            assert_eq!(
                bits(&run(&mut engine, &samples)),
                bits(&got),
                "{} repeat",
                arm.name()
            );
        }
    }
}

fn err_text(buffer: &[c_char]) -> String {
    // SAFETY: NUL-terminated by the callee (or still zeroed).
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

#[test]
fn c_abi_round_trip_and_errors() {
    let Some(fe) = frontend() else { return };
    let path = CString::new(pin::default_model_path().to_str().unwrap()).unwrap();
    let mut err = vec![0 as c_char; 256];
    // SAFETY (all calls below): valid strings, buffers sized as passed.
    unsafe {
        let bad = vm_engine_new(path.as_ptr(), c"nope".as_ptr(), err.as_mut_ptr(), err.len());
        assert!(bad.is_null());
        assert!(
            err_text(&err).contains("unknown arm 'nope'"),
            "{}",
            err_text(&err)
        );

        let missing = vm_engine_new(
            c"/nonexistent/model.bin".as_ptr(),
            c"best".as_ptr(),
            err.as_mut_ptr(),
            err.len(),
        );
        assert!(missing.is_null() && !err_text(&err).is_empty());

        let engine = vm_engine_new(
            path.as_ptr(),
            c"best-approx".as_ptr(),
            err.as_mut_ptr(),
            err.len(),
        );
        assert!(!engine.is_null(), "{}", err_text(&err));
        let samples = noise(16_000, 3, 0.3);
        let mut out = vec![f32::NAN; 120 * fe.n_mels];
        let frames = vm_compute(
            engine,
            samples.as_ptr(),
            16_000,
            out.as_mut_ptr(),
            120,
            128,
            err.as_mut_ptr(),
            err.len(),
        );
        assert_eq!(frames, 101);
        assert!(out[..101 * 128].iter().all(|v| v.is_finite()));
        assert!(
            out[101 * 128..].iter().all(|v| v.is_nan()),
            "wrote past n_frames"
        );

        let mut reference = Engine::new(Arc::clone(&fe), Arm::Faithful, 1).unwrap();
        assert_eq!(
            bits(&out[..101 * 128]),
            bits(&run(&mut reference, &samples))
        );

        assert_eq!(
            vm_compute(
                engine,
                samples.as_ptr(),
                16_000,
                out.as_mut_ptr(),
                100,
                128,
                err.as_mut_ptr(),
                err.len()
            ),
            -1
        );
        assert!(err_text(&err).contains("max_frames"), "{}", err_text(&err));
        assert_eq!(
            vm_compute(
                engine,
                samples.as_ptr(),
                16_000,
                out.as_mut_ptr(),
                120,
                80,
                err.as_mut_ptr(),
                err.len()
            ),
            -1
        );
        assert!(err_text(&err).contains("n_mels"), "{}", err_text(&err));
        assert_eq!(
            vm_compute(
                engine,
                std::ptr::null(),
                10,
                out.as_mut_ptr(),
                120,
                128,
                err.as_mut_ptr(),
                err.len()
            ),
            -1
        );
        assert_eq!(
            vm_compute(
                std::ptr::null_mut(),
                samples.as_ptr(),
                10,
                out.as_mut_ptr(),
                120,
                128,
                err.as_mut_ptr(),
                err.len()
            ),
            -1
        );
        // A 4-byte error buffer gets a truncated, NUL-terminated message.
        let mut small = [1 as c_char; 4];
        assert_eq!(
            vm_compute(
                engine,
                samples.as_ptr(),
                16_000,
                out.as_mut_ptr(),
                1,
                128,
                small.as_mut_ptr(),
                small.len()
            ),
            -1
        );
        assert_eq!(small[3], 0);
        assert_eq!(
            vm_compute(
                engine,
                std::ptr::null(),
                0,
                out.as_mut_ptr(),
                1,
                128,
                err.as_mut_ptr(),
                err.len()
            ),
            1
        );

        vm_engine_free(engine);
        vm_engine_free(std::ptr::null_mut());
    }
}

/// The repository root (this crate lives at `bench/rust/mel-frontend`).
fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

#[test]
fn first_dump_rows_match_the_native_mel() {
    let Some(fe) = frontend() else { return };
    let dumps = repo_root().join(".build/rust-bench/dumps");
    let mut checked = 0;
    for corpus in ["general96", "jargon456", "librispeech128"] {
        let index = dumps.join(corpus).join("index.jsonl");
        let Ok(text) = std::fs::read_to_string(&index) else {
            eprintln!("skipping {corpus}: no {}", index.display());
            continue;
        };
        let mut engines = [
            Engine::new(Arc::clone(&fe), Arm::Faithful, 1).unwrap(),
            Engine::new(Arc::clone(&fe), Arm::Best, 6).unwrap(),
        ];
        for line in text.lines().take(3) {
            let row: serde_json::Value = serde_json::from_str(line).unwrap();
            let field = |name: &str| row[name].as_str().unwrap().to_owned();
            let audio = std::fs::read(repo_root().join(field("audio_path"))).unwrap();
            assert_eq!(pin::sha256_hex(&audio), field("audio_sha256"));
            let samples = wav::read_samples(&audio).unwrap();
            assert_eq!(samples.len() as u64, row["n_samples"].as_u64().unwrap());
            let mel = std::fs::read(dumps.join(corpus).join(field("mel_file"))).unwrap();
            let reference: Vec<u32> = mel
                .chunks_exact(4)
                .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect();
            for engine in &mut engines {
                assert!(
                    bits(&run(engine, &samples)) == reference,
                    "{corpus} {}: {}",
                    field("id"),
                    engine.arm().name()
                );
            }
            checked += 1;
        }
    }
    eprintln!("checked {checked} dump rows");
}
