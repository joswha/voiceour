//! Decode-loop tests on synthetic tails (always run) and on the pinned model with the dumped
//! encoder states (skipped with a note when the model or the dumps are absent).

use std::path::{Path, PathBuf};

use tdt_tail::{Dims, Engine, Format, Mat, Token, Weights, arm_config, canonical};

const P: usize = 32;
const S: usize = 64;
const N_TOK: usize = 64; // 63 pieces + blank
const BLANK: usize = N_TOK - 1;
const DURATIONS: [i32; 5] = [0, 1, 2, 3, 4];

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> f32 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
    /// fp16-representable, so f32 and f16 storage hold the same weights.
    fn vec(&mut self, n: usize, scale: f32) -> Vec<f32> {
        (0..n)
            .map(|_| parakeet_model::f16_to_f32(parakeet_model::f32_to_f16(self.next() * scale)))
            .collect()
    }
}

/// A tail with random weights (`scale` 0 gives all-zero matrices) and the given joint bias.
fn synthetic(format: Format, seed: u64, scale: f32, net_b: Vec<f32>) -> Weights {
    let n_out = N_TOK + DURATIONS.len();
    assert_eq!(net_b.len(), n_out);
    let mut r = Lcg(seed);
    let mut mat =
        |rows: usize, k: usize, s: f32| Mat::from_f32(rows, k, &r.vec(rows * k, s), format);
    let w_ih = vec![mat(4 * P, P, scale), mat(4 * P, P, scale)];
    let w_hh = vec![mat(4 * P, P, scale), mat(4 * P, P, scale)];
    let pred_w = mat(P, P, scale);
    let enc_w = mat(P, S, scale);
    let net_w = mat(n_out, P, scale * 2.0);
    let mut r = Lcg(seed ^ 0x5eed);
    let mut embed: Vec<u16> = r
        .vec(N_TOK * P, 1.0)
        .into_iter()
        .map(parakeet_model::f32_to_f16)
        .collect();
    embed[BLANK * P..].fill(0);
    Weights {
        dims: Dims {
            p: P,
            s: S,
            n_tok: N_TOK,
            blank: BLANK,
            n_out,
            durations: DURATIONS.to_vec(),
            max_symbols: 10,
            n_layers: 2,
        },
        embed,
        w_ih,
        w_hh,
        b_h: vec![r.vec(4 * P, 0.5), r.vec(4 * P, 0.5)],
        pred_w,
        pred_b: r.vec(P, 0.5),
        enc_w,
        enc_b: r.vec(P, 0.5),
        net_w,
        net_b,
    }
}

fn engine(arm: &str, w: Weights) -> Engine {
    let cfg = arm_config(arm).unwrap();
    Engine::from_weights(arm, cfg, w).unwrap()
}

fn engine_for(arm: &str, seed: u64, scale: f32, net_b: &[f32]) -> Engine {
    let format = arm_config(arm).unwrap().format;
    engine(arm, synthetic(format, seed, scale, net_b.to_vec()))
}

fn bias(token: usize, token_logit: f32, dur_slot: usize) -> Vec<f32> {
    let mut b = vec![0.0; N_TOK + DURATIONS.len()];
    b[token] = token_logit;
    b[N_TOK + dur_slot] = 10.0;
    b
}

fn enc(n_frames: usize, seed: u64) -> Vec<f32> {
    Lcg(seed).vec(n_frames * S, 1.0)
}

fn decode(e: &mut Engine, enc: &[f32], n_frames: usize) -> (Vec<Token>, tdt_tail::Work) {
    let mut out = Vec::new();
    let work = e.decode(enc, n_frames, S, &mut out, None).unwrap();
    (out, work)
}

const ALL_ARMS: [&str; 10] = [
    "naive",
    "precompute",
    "rawargmax",
    "f16w",
    "mt/t=4",
    "spec/t=4",
    "accel",
    "q8/t=4",
    "best/t=3",
    "c-best/t=3",
];

#[test]
fn forced_advance_after_ten_symbols_on_one_frame() {
    // Zero matrices: every step emits token 5 with duration 0, so each frame yields exactly
    // n_max_tokens = 10 symbols before the forced advance.
    for arm in ALL_ARMS {
        let mut e = engine_for(arm, 1, 0.0, &bias(5, 10.0, 0));
        let (toks, work) = decode(&mut e, &enc(4, 2), 4);
        assert_eq!(toks.len(), 40, "{arm}");
        for (i, t) in toks.iter().enumerate() {
            assert_eq!(
                (t.id, t.frame_index, t.duration_idx, t.duration),
                (5, (i / 10) as i32, 0, 0),
                "{arm} token {i}"
            );
            assert!(
                t.p > 0.99 && t.plog < 0.0 && t.plog.is_finite(),
                "{arm}: p {} plog {}",
                t.p,
                t.plog
            );
        }
        assert_eq!(work.n_steps, 40, "{arm}");
        assert_eq!(
            work.n_pred, 40,
            "{arm}: the last token's prediction is never consumed"
        );
    }
}

#[test]
fn blank_with_duration_zero_advances_one_frame() {
    for arm in ALL_ARMS {
        let mut e = engine_for(arm, 1, 0.0, &bias(BLANK, 10.0, 0));
        let (toks, work) = decode(&mut e, &enc(7, 3), 7);
        assert!(toks.is_empty(), "{arm}");
        assert_eq!((work.n_steps, work.n_pred), (7, 1), "{arm}");
        // A blank with duration 3 skips three frames: steps at 0, 3, 6.
        let mut e = engine_for(arm, 1, 0.0, &bias(BLANK, 10.0, 3));
        let (toks, work) = decode(&mut e, &enc(7, 3), 7);
        assert!(toks.is_empty(), "{arm}");
        assert_eq!(work.n_steps, 3, "{arm}");
    }
}

#[test]
fn token_and_duration_ties_take_the_first_maximum() {
    // Equal token logits at 10 and 50 (different thread partitions for t=4) and equal duration
    // logits at slots 1 and 3: the first of each wins, in every arm.
    let mut b = vec![0.0; N_TOK + DURATIONS.len()];
    b[10] = 7.0;
    b[50] = 7.0;
    b[N_TOK + 1] = 9.0;
    b[N_TOK + 3] = 9.0;
    for arm in ALL_ARMS {
        let mut e = engine_for(arm, 1, 0.0, &b);
        let (toks, _) = decode(&mut e, &enc(3, 4), 3);
        assert_eq!(canonical(&toks), "10:0:1,10:1:1,10:2:1", "{arm}");
        assert!(toks.iter().all(|t| t.duration_idx == 1));
    }
}

#[test]
fn zero_frames_decode_to_nothing() {
    for arm in ALL_ARMS {
        let mut e = engine_for(arm, 1, 0.5, &bias(5, 10.0, 0));
        let (toks, work) = decode(&mut e, &[], 0);
        assert!(toks.is_empty(), "{arm}");
        assert_eq!(
            (work.n_steps, work.n_pred, work.n_tokens),
            (0, 0, 0),
            "{arm}"
        );
    }
}

#[test]
fn spec_windows_are_bit_identical_to_single_columns() {
    let net_b = Lcg(9).vec(N_TOK + DURATIONS.len(), 1.0);
    let x = enc(23, 5);
    for arm in [
        "spec/t=1/k=7",
        "spec/t=4/k=5",
        "spec/t=3/k=4/kt=3",
        "mt/t=2",
    ] {
        let mut e = engine_for(arm, 3, 0.6, &net_b);
        for (token, t, k) in [
            (BLANK, 0, 4),
            (7, 3, 5),
            (20, 15, 8),
            (63, 1, 1),
            (2, 16, 7),
        ] {
            let (single, batched) = e.probe_window(&x, 23, token, t, k);
            assert_eq!(single.len(), batched.len());
            assert!(
                single
                    .iter()
                    .zip(&batched)
                    .all(|(a, b)| a.to_bits() == b.to_bits()),
                "{arm}: window ({token},{t},{k}) differs"
            );
        }
    }
}

#[test]
fn exact_arms_agree_bit_for_bit_on_random_tails() {
    let net_b = Lcg(11).vec(N_TOK + DURATIONS.len(), 1.5);
    let mut emitted = 0;
    for seed in 0..12u64 {
        let n_frames = 9 + seed as usize * 5;
        let x = enc(n_frames, 100 + seed);
        let reference = {
            let mut e = engine_for("rawargmax", seed, 0.7, &net_b);
            decode(&mut e, &x, n_frames).0
        };
        emitted += reference.len();
        for arm in [
            "f16w",
            "mt/t=4",
            "mt/t=7",
            "spec/t=4",
            "spec/t=1/k=6",
            "spec/t=5/k=3/kt=2",
            "best",
            "c-best/t=4",
            "c-best/t=2/k=4",
        ] {
            let mut e = engine_for(arm, seed, 0.7, &net_b);
            let (toks, _) = decode(&mut e, &x, n_frames);
            assert_eq!(toks.len(), reference.len(), "{arm} seed {seed}");
            for (a, b) in toks.iter().zip(&reference) {
                assert_eq!(
                    (a.id, a.frame_index, a.duration_idx, a.duration),
                    (b.id, b.frame_index, b.duration_idx, b.duration),
                    "{arm} seed {seed}"
                );
                assert_eq!(
                    (a.p.to_bits(), a.plog.to_bits()),
                    (b.p.to_bits(), b.plog.to_bits()),
                    "{arm} seed {seed}"
                );
            }
            // A second call on the same engine reproduces the first (state is reset per call).
            let (again, _) = decode(&mut e, &x, n_frames);
            assert_eq!(again, toks, "{arm} seed {seed} not repeatable");
        }
        // naive / precompute share the log-prob argmax and agree with each other bit for bit.
        let mut a = engine_for("naive", seed, 0.7, &net_b);
        let mut b = engine_for("precompute", seed, 0.7, &net_b);
        assert_eq!(
            decode(&mut a, &x, n_frames).0,
            decode(&mut b, &x, n_frames).0,
            "naive vs precompute seed {seed}"
        );
    }
    assert!(emitted > 50, "random tails should emit tokens ({emitted})");
}

// ----- pinned model + dumps ---------------------------------------------------------------------

fn dumps_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/rust-bench/dumps")
}

#[derive(serde::Deserialize)]
struct Row {
    id: String,
    n_enc_frames: usize,
    n_state: usize,
    enc_file: String,
    #[serde(rename = "ref")]
    reference: serde_json::Value,
}

fn first_rows(corpus: &str, n: usize) -> Option<Vec<(Row, Vec<f32>)>> {
    let dir = dumps_dir().join(corpus);
    let text = std::fs::read_to_string(dir.join("index.jsonl")).ok()?;
    Some(
        text.lines()
            .take(n)
            .map(|l| {
                let row: Row = serde_json::from_str(l).unwrap();
                let bytes = std::fs::read(dir.join(&row.enc_file)).unwrap();
                let enc = bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                    .collect();
                (row, enc)
            })
            .collect(),
    )
}

#[test]
fn pinned_model_exact_arms_match_and_reproduce_ref() {
    let model = parakeet_model::pin::default_model_path();
    if !model.is_file() {
        eprintln!("skipping: model not at {}", model.display());
        return;
    }
    let Some(rows) = first_rows("jargon456", 6) else {
        eprintln!("skipping: no dumps under {}", dumps_dir().display());
        return;
    };
    let mut engines: Vec<Engine> = [
        "rawargmax",
        "f16w",
        "mt",
        "spec",
        "best",
        "c-best",
        "spec/k=8/kt=2",
    ]
    .iter()
    .map(|arm| Engine::new(&model, arm).unwrap())
    .collect();
    let mut equal_ref = 0;
    for (row, x) in &rows {
        let mut outputs = Vec::new();
        for e in engines.iter_mut() {
            let mut toks = Vec::new();
            e.decode(x, row.n_enc_frames, row.n_state, &mut toks, None)
                .unwrap();
            outputs.push(toks);
        }
        for (i, o) in outputs.iter().enumerate().skip(1) {
            assert_eq!(
                o,
                &outputs[0],
                "{} differs from rawargmax on {}",
                engines[i].name(),
                row.id
            );
            assert!(o.iter().zip(&outputs[0]).all(
                |(a, b)| a.p.to_bits() == b.p.to_bits() && a.plog.to_bits() == b.plog.to_bits()
            ));
        }
        let reference: Vec<String> = row.reference["tokens"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| format!("{}:{}:{}", t["id"], t["frame_index"], t["duration"]))
            .collect();
        equal_ref += usize::from(canonical(&outputs[0]) == reference.join(","));
    }
    assert!(
        equal_ref >= rows.len() - 1,
        "only {equal_ref}/{} rows reproduce ref",
        rows.len()
    );
    // One spec window on real weights: batched logits equal the single-column ones.
    let (row, x) = &rows[0];
    let mut e = Engine::new(&model, "spec").unwrap();
    let (single, batched) = e.probe_window(x, row.n_enc_frames, 8192, 2, 6);
    assert!(
        single
            .iter()
            .zip(&batched)
            .all(|(a, b)| a.to_bits() == b.to_bits())
    );
}
