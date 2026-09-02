# glossary-conditioned-decoding wave1 run1 — how to run Stage 2

Preregistration: `research/prereg/glossary-conditioned-decoding-wave1.md`, freeze commit `898262c`.
Bars: `recall_hits >= 262` meaningful, `>= 279` strong, `< 254` kill; `uwer_general <= .034225`.

Stage 2 decodes no audio and loads no CoreML model. Its only external process is the
prebuilt tail runner. Run Stage 1 first (`glossary-conditioning dump-states`, exclusive
hardware, parent-serialized); Stage 2 refuses to run without `--states` and `--index`.

## 0. Inspect the frozen constants, the embedding tensor, and the deviation list

```sh
cd /Users/vlad/Desktop/voiceoour && bench/.venv/bin/python .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/glossary_conditioned_replay.py --describe
```

Exits non-zero if the tokenizer disagrees with the cached lattices on any recorded token id,
if any cached transcript fails to re-render, or if the unrepresentable canonical set is not
exactly `C#`, `C++`, `io_uring`. Observed on this checkout: 23,366 chosen tokens checked,
0 mismatches, 0 re-render mismatches, 552/552 transcript round trips;
`decoder.prediction.embed.weight` F16 `ne=[640, 8193]` at byte 1,219,620,741, 10,487,040
bytes, payload sha256 `3173388a…` — read as F32 `[8193, 640]` (row per token id).

## 1. Dry run (no Stage 1 needed, ~10 s)

Fabricates a synthetic state pack and stubs the tail with the baseline text, so the whole
pipeline runs: GGML read, tokenizer, term vectors, glossary, split, training, eta/tau
selection, pack writing, replay orchestration, renderer, endpoints, bootstrap, permutation,
identity controls, and every artifact. Write it under `/tmp`, never into the run directory.

```sh
cd /Users/vlad/Desktop/voiceoour && rm -rf /tmp/gcd-dry && env PYTHONHASHSEED=0 VECLIB_MAXIMUM_THREADS=6 bench/.venv/bin/python .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/glossary_conditioned_replay.py --dry-run --output /tmp/gcd-dry/run1
```

`--dry-run-rows 8` widens it to two canonical pairs plus four negative rows, which also
exercises the null branch, the activation guard, and the Clopper-Pearson upper bound.
Dry-run output is never evidence; `verdict.md` says so on its second line.

## 2. Stage 1 (the parent, exclusive hardware — not this script)

```sh
cd /Users/vlad/Desktop/voiceoour && make stop && env VOICEOUR_COREML_ENCODER_TINY="$PWD/.build/asr-research/three-bets/palettize6/tiny/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_TINY_MAX_S=6.0 VOICEOUR_COREML_ENCODER_SHORT="$PWD/.build/asr-research/three-bets/palettize6/short/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_SHORT_MAX_S=8.0 VOICEOUR_COREML_ENCODER="$PWD/.build/asr-research/three-bets/palettize6/standard/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_MAX_S=15.0 .build/release/voiceour-bench glossary-conditioning dump-states --input benchmarks/data/jargon/manifest.jsonl --lattice .build/asr-research/three-bets/margins/jargon456.lattice.jsonl --model "$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin" --output .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump
```

Do **not** pass `--vocabulary`: Stage 2 wants `baseline_final_text` to be
`CleanupEngine.clean(raw, glossary: [])` only, so M0 is the bare-ASR structural-null control
and not the shipped repair. Stage 2 verifies raw-vs-final canonical containment agreement on
every index row and reports `baseline_domain_disagreements`.

## 3. Stage 2 — the single command that reproduces the run

Verbatim from the preregistration (recorded again in `run1/command.txt` by the script):

```sh
cd /Users/vlad/Desktop/voiceoour && env PYTHONHASHSEED=0 VECLIB_MAXIMUM_THREADS=6 bench/.venv/bin/python .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/glossary_conditioned_replay.py --states .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump/states.f32 --index .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump/index.jsonl --terms bench/autoresearch/jargon.terms.json --jargon-lattice .build/asr-research/three-bets/margins/jargon456.lattice.jsonl --general-lattice .build/asr-research/three-bets/margins/general96.lattice.jsonl --contrastive-rows .build/asr-research/next/data-foundation/contrastive-homophone-training/wave1/run1/rows.jsonl --model "$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin" --tail-runner .build/release/voiceour-bench --output .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1
```

Every other input the script needs is a default that already points at the pinned path:
`--jargon-manifest benchmarks/data/jargon/manifest.jsonl`,
`--general-corpus bench/autoresearch/corpus.manifest.jsonl`,
`--general-results .build/autoresearch/general.results.jsonl`,
`--repair-vocabulary bench/autoresearch/repair.vocabulary.json`,
`--prereg research/prereg/glossary-conditioned-decoding-wave1.md`,
`--bench-src bench/src`. All digests land in `manifest.json`.

Optional switches, none of which changes a preregistered quantity:
`--keep-packs` retains the adapted state packs under `<output>/packs/` instead of deleting
them after their replay; `--strict-span-map` turns an unmappable localization span into a
hard stop instead of a reported fit-set exclusion; `--no-identity-controls` skips I0/I1 (do
not use for the real run — they are required evidence); `--stub-replay` substitutes the
baseline text for the tail against a real Stage 1 pack, for a plumbing check only;
`--verdict <path>` moves `verdict.md` (default `<output>/../verdict.md`).

## What the script invokes, exactly

```sh
.build/release/voiceour-bench glossary-conditioning replay-states \
    --input <fold manifest.jsonl> --states <fold states.f32> \
    --index <fold index.jsonl>   --output <replay rows.jsonl> \
    --model "$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin"
```

`--model` is required by the built subcommand (verified against
`.build/release/voiceour-bench`, sha256 `fb32b3f0…`) and is taken from this script's
`--model`. Note the built `dump-states` spells its destination `--output-dir`, not
`--output` as the preregistration's Stage 1 command line writes it — adjust that command
when running Stage 1.

Every `VOICEOUR_COREML_*` variable is stripped from the child environment. Ten invocations
in total: three cached fit replays per fold (one per
`eta ∈ {.05,.10,.20}`), one out-of-fold test replay per fold, and one 456-row replay for each
identity control. Per-fold indexes carry exactly `id`, `byte_offset`, `byte_count`,
`frame_count` (copied verbatim from Stage 1, never recomputed), `width` (always 1024); the
filtered manifests are unmodified copies of the matching `benchmarks/data/jargon/manifest.jsonl`
records, so the runner's `audio_bytes`/`audio_sha256` validation still passes. The script
reads `id`, `raw_text`, `transcript_sha256`, `frame_count`, and — when present —
`cleaned_text` and `tokens[{piece,text,start_ms,end_ms}]`, from which the renderer derives
its exact encoder-frame map (`encoder_frame = start_ms / 10 / 8`).

## Artifacts

Under `<output>` (nothing is overwritten; the script aborts if a file already exists):
`manifest.json` (pin keys, environment identity, `screen_inputs`, prereg sha256 and freeze
commit, fold operating points, identity controls, deviations), `metrics.jsonl` (one
`{"run","metric","value"}` record per metric, `-1` for an undefined measurement),
`rows.jsonl` (per-row id, fold, snapshot ids, label and provenance, selected id or null,
score, tau, eta, frame and span, M0/M1 texts and hashes, correctness, every safety flag),
`command.txt`, `embedding-metadata.json`, `fold-{A,B}/weights.npz`,
`fold-{A,B}/optimizer-report.json` (loss/grad-norm history plus the full (eta, tau) grid),
`replay/*.rows.jsonl`. `verdict.md` and `prereg.md` land in the wave directory one level up.

## Expected wall clock

Training is two folds × 256 AdamW updates over ~50 MB of F32 states, a few minutes. The
tail replays dominate: ten CPU replays covering ~2,700 row decodes. The preregistration
kills the run above eight hours; the script records `runtime_seconds` and applies that gate.
