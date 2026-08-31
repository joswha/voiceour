# Voiceour three-bets research session — context pack

**Read this first.** Every subagent in this session starts cold; this file is the shared
memory. It compresses five scout reports (2026-08-31) plus the committed docs into the facts
a research task needs. Cite it as `research/CONTEXT.md`; verify against source before
building on a claim marked [stale-risk].

## The product in one paragraph

Voiceour is a local-first macOS menu-bar dictation app (Apple Silicon only, macOS 14+).
One Fn/Globe tap records one utterance; stop finalizes one 16 kHz mono WAV and performs
**one final decode** in a persistent signed sidecar (`voiceour-asr`, vendored
parakeet.cpp/ggml, Metal), then deterministic cleanup + glossary canonicalization, then
paste/copy into the frontmost app. Non-goals (product decisions, in `docs/non-goals.md`):
no streaming/partial transcript, no model-based rewriting after recognition, no second
recognizer, no telemetry, no saved audio, English only.

## Model + runtime

- Model: `ggml-org/parakeet-GGUF` rev `35156454d1a39de06863303dd209fd2bed6ee079`,
  f16 artifact `ggml-parakeet-tdt-0.6b-v3-f16.bin` (1,255,897,319 B). q8_0 variant exists
  (668,757,119 B), 7–19% **slower** than f16 on Metal (kernel inefficiency, unexplained).
- Architecture (Vendor/parakeet/src/parakeet-arch.h:208-238): FastConformer encoder,
  24 layers, d=1024, 8 heads, 128 mels, subsample 8×, conv kernel 9; prediction net
  2×LSTM d=640; TDT joint with 5 duration slots, max 10 tokens/timestep; vocab 8192.
- Decode: **greedy TDT only** (`PARAKEET_SAMPLING_GREEDY`), `n_threads=4` hardcoded
  (`Sources/ASRSidecarCore/ParakeetContext.swift`). No beam, no n-best.
- Metal: GPU+Accelerate+CPU split; `n_cb=3` hardcoded (Vendor .../ggml-metal.cpp:610-622,
  716-728); poll loop 50k iterations (~200 µs cap). Local attention only engages above
  8192 encoder frames (~10.9 min audio); ordinary dictations are full attention.
- Weights load via a file-backed read-only arena (v0.2.1): peak footprint ~178 MB,
  RSS ~113 MB. Cold model load ~3.5 s (f16); first-ever Metal shader compile ~7.5 s.
- Token data exposed by vendored decoder: per-token `p` (softmax over vocab+blank,
  duration slots excluded), `plog`, `t0/t1`, `is_word_start`. Full logits + token
  callbacks exist in the header but are **unused**. Confidence on the wire: word = min
  piece p, transcript = mean token p. **Uncalibrated**: LibriSpeech mean conf .9723,
  ECE .621; FLEURS ECE .568.

## Baselines (M4 Pro, macOS 26.5.2, f16, 2026-08-15 committed reports)

| corpus | U-WER | CER | ASR p50/p95 | RTFx |
|---|---:|---:|---:|---:|
| LibriSpeech 128 | 2.807% | 0.882% | 201/274 ms | 113.0 |
| FLEURS 64 | 4.416% | 1.929% | 90.5/125 ms | 99.9 |

FLEURS formatting: case F1 .9218, punct micro F1 .8380, FWER 10.03%.

## The three bets

1. **Contextual decoding** — calibrate confidence, locate suspect spans, re-decode only
   those spans decoder-only on cached encoder output with a token-trie
   (failure-arc/Aho-Corasick) vocabulary automaton, per-term boosts solved as
   max-recall-s.t.-FRR≤α. Killed prior art (do not repeat naively): flat 20k-list bias
   (WER 9.86→11.42), flat phrase-trie boost (FRR 0→.4, WER +12.5 pp), beam-only k-best
   (recall .545 < greedy .636; 5/11 missed terms absent from whole beam).
2. **Heterogeneous execution** — FastConformer encoder via CoreML on ANE, TDT loop on
   CPU. Same pinned weights: an execution-engine change, not a second recognizer. Open
   questions: op coverage, static shapes/padding buckets, f16 divergence vs Metal,
   run-to-run determinism on ANE, energy per utterance.
3. **Quantization frontier** — first make q8 kernels not-slower (fused dequant-matmul);
   then mixed-precision per-layer assignment; the theory piece is a **greedy-TDT margin
   stability analysis**: harvest top-2 logit margins per decode step, model quantization
   as bounded logit perturbation, predict transcript-flip probability before evaluating.
   Prior: TDT duration head (5 slots) is suspected quantization-fragile.

## The harness (this session's measurement instrument)

`bash autoresearch.sh` → `METRIC` lines. Primary: **`uwer_mix`** (lower is better) =
pooled final-text U-WER over general96 ∪ jargon456. Guards enforced in-script: general
inference p95 ≤ 300 ms, RTFx ≥ 40, peak footprint ≤ 2500 MB, zero error rows, cross-pass
transcript determinism. Secondary metrics: `uwer_general`, `uwer_jargon`,
`jargon_term_recall` (case-sensitive exact canonical), `jargon_false_terms`,
`fwer_negative` (case-preserving guard on 110 ordinary-prose negatives — U-WER folds
case, so re-casing damage is invisible to the primary), latency/RTFx/load/memory.

Corpora (frozen, SHA-pinned in autoresearch.sh):
- `bench/autoresearch/corpus.manifest.jsonl` — 96 rows (32 LS clean, 32 LS other,
  32 FLEURS), 1944 s, five duration buckets.
- `benchmarks/data/jargon/manifest.jsonl` — 456 rows, 1943 s, synthetic `say` speech:
  346 positives (cloud 72, security 68, langs 72, apple 68, dataweb 66; id pattern
  `jg_NNNN_<domain>_<termslug>`) + 110 hard negatives (ordinary prose containing
  `rust`, `swift`, `metal`, `python`, `react`, `node`, `commit`, `merge`…).
  Term ground truth: `bench/autoresearch/jargon.terms.json` (187 distinct surfaces,
  derived by `derive_jargon_terms.py`).
- Synthetic caveat: one macOS voice. Optimization signal only; product promotion still
  requires the real-speaker gate (`docs/benchmarks.md` paired gate: NI +0.35 pp,
  benefit ≥0.5 pp).

## Cardinal rules for research agents

- **Determinism**: same input → same output. No RNG without fixed seeds, no wall-clock
  dependence, no network. The harness rejects cross-pass transcript drift.
- **Vendored code**: every change to `Vendor/parakeet/**` upstream files carries a
  `VOICEOUR PATCH` marker comment and a `Vendor/parakeet/NOTICE.md` ledger entry.
  `scripts/vendor_parakeet.sh --check` must stay green. Never `-mcpu=native`.
- **Protocol**: NDJSON v1 over stdio; change wire models, client+server encoding, and
  `fixtures/protocol/` together. One terminal response per request.
- **VoiceCore stays Foundation-only.** macOS APIs live in VoiceMac. The sidecar is the
  only child process; model download is the only permitted network path (and the
  harness refuses even that).
- **Do not run** formatters, `make check`, or project-wide test suites inside research
  tasks unless the task says so; the session runs gates centrally.
- **Do not touch** `fixtures/ui/**` goldens, `Resources/**` signing/entitlements.
- Build: `swift build -c release --product voiceour-asr` (+ `voiceour-bench`).
  Real-model smoke: `.build/release/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav`.
- Experiment scratch space: `.build/asr-research/` (gitignored). Prior sessions left
  artifacts there — k-best oracles, CoreML probes, granite/nemotron comparisons. Treat
  as exploratory evidence, not verified truth.

## Wiki map

- `research/INDEX.md` — session log + state of each bet (update after every milestone).
- `research/bet1-contextual-decoding.md` — Bet 1 living notes.
- `research/bet2-ane-encoder.md` — Bet 2 living notes.
- `research/bet3-quantization.md` — Bet 3 living notes.
- `research/harness.md` — metric definitions, corpus anatomy, how to run.
