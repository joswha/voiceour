# tdt-tail

Benchmark-only Rust TDT decode tail for bet B1 of the Rust proof program: the prediction LSTM, the
joint network and the greedy TDT loop of Voiceour's vendored parakeet.cpp, replayed on dumped
encoder states. Nothing in the app depends on it. It builds `libtdt_tail.dylib` (the `vt_` C ABI
the Swift harness loads with `dlopen`), the `tail-bench` binary and a C11 control arm.

Line references are to `Vendor/parakeet/src/parakeet.cpp` unless another file is named.

## Build, run, test

```sh
cd bench/rust/tdt-tail
cargo build --release          # libtdt_tail.dylib + tail-bench; build.rs compiles c/vt_c.c
cargo test --release           # unit, synthetic-decode and pinned-model/dump tests
nm -gU target/release/libtdt_tail.dylib    # _vt_abi_version _vt_arms _vt_decode _vt_engine_free _vt_engine_new

D=../../../.build/rust-bench/dumps
./target/release/tail-bench --dumps $D --equivalence ../../../.build/rust-bench/b1/equivalence.json
./target/release/tail-bench --dumps $D --passes 3 --output rows.jsonl          # all arms, contract rows
./target/release/tail-bench --dumps $D --corpus general96 --limit 12 --profile 3   # phase breakdown
```

The pinned-model test skips itself (note on stderr) when the model or the dumps are absent.
`--dumps` takes one corpus directory or a directory of them; `--limit N` keeps the first N rows of
each corpus, `--model` overrides the pinned model path.

## The native tail (verified)

- `parakeet_decode` (L4761-L4947): `t = 0`, last token = blank (8192), one merged step graph per
  iteration (`parakeet_step`, prediction included when a token was emitted on the previous step).
  Token argmax: `best = 0, max = -1e10`, strict `>` over the **log-probs** of slots 0..8192
  (L4829-L4836). Duration argmax: first maximum over the **raw** duration logits (L4841-L4856).
  Blank: duration 0 becomes 1, `t += duration`, symbol counter reset (L4878-L4888). Token: emit at
  `t` (L4890-L4899); duration > 0 advances `t`; duration 0 stays, and after `n_max_tokens = 10`
  symbols on one frame `t += 1` (L4913-L4926). A prediction still pending at loop exit runs once
  more (L4938-L4944); nothing observes it.
- Step graph (L4474-L4528): `enc = enc_w·enc[t] + enc_b`, `joint = relu(enc + pred)`,
  `logits = net_w·joint + net_b` over 8192 + 1 + 5 slots, `soft_max` then `log` over all 8198.
  The patch comment at L4459-L4468 measured ~170 µs of fixed cost per graph compute on Metal.
- LSTM (L4323-L4389): `gates = W_ih·x + (W_hh·h + b_h)`, gates packed `[i, f, o, c]`,
  `σ` on i/f/o, `tanh` on c, `c' = f·c + i·g`, `h' = o·tanh(c')`. Prediction (L4397-L4434): the
  embedding row of the token (blank row is zero), two layers, `pred = pred_w·h + pred_b`.
- `create_token_data` (L4731-L4759): `p = expf(lp_best) / Σ_{i<8193} expf(lp_i)` with `lp` the
  log-probs, `plog = lp_best`, `t0 = 8·frame`, `t1 = 8·(frame + duration)`.

## Arms

Each arm adds one step to the previous one (`q8`, `accel`, `c-best` branch off). Names select
them through `vt_engine_new` and `tail-bench --arms`; `arm/t=N` (threads), `/k=N`, `/kt=N` (spec
frames after a blank / after a prediction), `/spin=µs`, `/defer=0|1` are development overrides.

| arm | weights | encoder projection | token argmax | threads | other |
|---|---|---|---|---|---|
| `naive` | f32 (widened at load) | matvec every step | log-softmax every step | 1 | |
| `precompute` | f32 | one GEMM over all frames before the loop | log-softmax every step | 1 | |
| `rawargmax` | f32 | GEMM | raw logits; log-softmax only for an emitted token's p/plog | 1 | |
| `f16w` | fp16, widened in NEON (`fcvtl`), f32 accumulation | GEMM | raw | 1 | |
| `mt` | fp16 | GEMM, split over the pool | raw, per-thread partial maxima | perf cores − 1 (9) | p/plog deferred, computed in parallel after the loop |
| `spec` | fp16 | GEMM | raw | 9 | one `net_w` pass evaluates frames `t..t+K` (K = 4 after a blank, 1 after a prediction) |
| `accel` | f32 | `cblas_sgemm` | raw | 1 caller (Accelerate threads itself) | `cblas_sgemv` for every product |
| `q8` | q8_0 (native `VOICEOUR_TAIL_QUANT=q8_0` repack) | GEMM | raw | 9 | `best` design, q8_0 activations, `sdot` |
| `best` | alias of `mt` (see "Choosing best") | | | | |
| `c-best` | fp16 | | | 9 | `best` written in C11 (`c/vt_c.c`), own pthread pool |

The pool (`src/pool.rs`, mirrored in C) keeps workers spinning on a generation word between jobs
and parks them on it with `os_sync_wait_on_address` after 2 ms, or at once between decodes; a
publish that finds parked workers wakes them with one `os_sync_wake_by_address_all`. Workers run at
`QOS_CLASS_USER_INTERACTIVE`. Matvec rows are split statically (LSTM by hidden unit, so each thread
finishes its own cell update): per token step four jobs (layer 0, layer 1, `pred`, joint), per blank
step one. The caller is participant 0.

## Exactness

Every exact arm computes every dot product in one canonical order (`src/kernels.rs`): two
`float32x4_t` accumulators over 8-element chunks (`a` += elements 0-3, `b` += 4-7, fused
multiply-add), result `vaddvq_f32(a + b)`; multi-row, multi-column (GEMM, spec) and threaded kernels
keep one accumulator pair per output element, and fp16 widening is exact. Biases are added after
the dot, in the native order. `exp`/`log`/`sigmoid`/`tanh` are NEON implementations shared by all
arms (`src/simd.rs`; within 2 ulp of libm for exp/log, 4 ulp for tanh, sigmoid within 2e-7 —
unit-tested), and so are the log-softmax and its sums. C repeats the same intrinsics and constants
and is compiled with `-ffp-contract=off`. Consequently `precompute`, `rawargmax`, `f16w`, `mt`, `spec`,
`best` and `c-best` produce bit-identical logits; `tests/engine.rs` asserts it on random tails and on
the pinned model, and asserts that spec windows equal single columns bit for bit.

## Results (development runs on a shared machine — not official)

### Equivalence, all 680 rows

`tail-bench --equivalence` (every arm once per row, traced and untraced; output identical).
`=ref`: canonical token string equal to the Metal tail; `=ref_cpu`: equal to the CPU tail;
`≡rawargmax`: tokens, p bits and plog bits identical to `rawargmax`.

| corpus | rows | exact arms `=ref` | exact arms `=ref_cpu` | exact arms `≡rawargmax` | plog max \|Δ\| vs ref | p max \|Δ\| vs ref | `accel` =ref | `q8` =ref |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| general96 | 96 | 96 | 94 | 96 | 1.14e-5 | 8.2e-6 | 96 | 39 |
| jargon456 | 456 | 456 | 454 | 456 | 1.14e-5 | 7.0e-6 | 456 | 390 |
| librispeech128 | 128 | 128 | 125 | 128 | 9.5e-6 | 9.6e-6 | 128 | 42 |

Exact arms are `naive`, `precompute`, `rawargmax`, `f16w`, `mt`, `spec`, `best`, `c-best` (the log-prob
argmax of `naive`/`precompute` picked the same token as the raw argmax on every step). They differ
from `ref_cpu` on exactly the 7 rows where `ref_cpu` itself differs from `ref`. `accel` matches every
token string but is never bit-identical (Accelerate's own summation order; plog max |Δ| 1.5e-5).
`q8` matches 471/680 rows: 180 of its 209 first divergences are duration decisions with raw
duration margins of median 0.04-0.07 (max 0.27), i.e. q8 perturbs logits enough to flip near-ties.

### Step statistics

Over the 680 rows the greedy loop takes 39,842 steps for 86,876 frames and 36,188 tokens: 91% of
steps emit a token (and run the prediction network), and 92% of blank runs have length 1. A
speculative window under one predictor state therefore serves almost nothing: K = 4 cuts joint
passes by 0.6% while computing 14-24% more columns. This is why `spec` cannot beat `mt`.

### Timing smoke

`tail-bench --limit 10 --passes 2` (first 10 rows of each corpus, pass 1, 1-min load 3.3-3.8):

| arm | Σ ms, 30 rows | µs/step (Σ/Σ) | median µs/step | =ref |
|---|---:|---:|---:|---:|
| naive | 1764.5 | 738.3 | 743.4 | 30/30 |
| precompute | 1644.7 | 688.2 | 692.9 | 30/30 |
| rawargmax | 1652.0 | 691.2 | 686.6 | 30/30 |
| f16w | 1130.8 | 473.1 | 472.8 | 30/30 |
| mt | 199.3 | 83.4 | 70.7 | 30/30 |
| spec | 202.7 | 84.8 | 71.2 | 30/30 |
| accel | 776.1 | 324.7 | 330.5 | 30/30 |
| q8 | 104.2 | 43.5 | 40.2 | 16/30 |
| best | 179.8 | 75.2 | 67.6 | 30/30 |
| c-best | 201.6 | 84.4 | 67.5 | 30/30 |

`fleurs-en_us-test-000001` (133 frames, 45 steps, 38 tokens): `f16w` 20.8 ms, `best` 2.97 ms,
`c-best` 2.93 ms, `q8` 1.90 ms. For scale only: the orchestrator's stage profile of that row put the
Metal tail at 18.96 ms (a different run).

Phase profile (`--profile 3`, 12 general96 rows, per step): `naive` 741 µs (prediction 364, joint
363 including the per-step encoder projection); `precompute` 685 (GEMM 31, joint 286); `f16w` 472
(prediction 234, joint 194); `mt` 73 (setup 5, prediction 39, joint 27, caller-serial 0.7,
deferred p/plog 1.7); `q8` 45.

### Thread count

Dev sweeps (`mt/t=N`, min over repetitions, 4 rows, load 5-7): 9 threads ~66 µs/step, 8 ~71,
7 ~79, 10 erratic (76-94) because one of the 10 P-cores is always busy with something else and a
statically split step waits for its slowest thread. `c-best` behaves the same (9: ~66, 10: 66-85).

## Choosing best

`best` = `mt`: the fastest arm that is bit-identical to `rawargmax`. `spec` computes strictly more
columns for a negligible cut in passes (step statistics above); `q8` is faster but changes tokens on
31% of rows; `accel` is exact on tokens but slower than `mt` and not bit-identical. `c-best` runs at
the same speed as `best`, so the gain is the design (parallel CPU arithmetic with ~µs sync per job
instead of a GPU graph per step), not the language.

## Differences from the native tail

- The trailing prediction after the loop (L4938) is not run; `n_pred` counts the predictions that do.
- `exp`/`log`/`tanh` are this crate's NEON functions (not libm or Metal's); dot products use the
  canonical order, not Metal's simdgroup reduction. Effect: plog within 1.2e-5 of `ref`.
- `q8` follows ggml's NEON `quantize_row_q8_0` and non-i8mm `ggml_vec_dot_q8_0_q8_0`; a native build
  with i8mm or FMA contraction differs in the last bits. There is no native q8 dump to compare with.
- `mt` defers p/plog to a parallel pass after the loop (output-only values; same function).

## Open risks

- All timing above is development data from a shared, loaded machine; official numbers come from
  the orchestrator's quiet runs. Thread count 9 was chosen under that load; a quiet machine may
  prefer 10 (`mt/t=10`).
- The caller is participant 0: a harness thread at low QoS (E-core) slows every step.
- Multi-threaded arms spin 9 P-cores during a decode (energy), park between decodes.
