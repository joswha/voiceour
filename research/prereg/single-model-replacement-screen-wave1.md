# Preregistration — single-model-replacement-screen, Wave 1

Track `single-model-replacement-screen` (A-tier, workstream `single-model`). Frontier of
record `0ac7514`; source checkout `d314b56`; contract `research/next-program.md`. Written
before any candidate download or decode. The commit adding this file is the freeze. Part 1
is a cached, CPU-only manifest freeze; Part 2 is blocked until the declared runtimes and
pinned downloads exist. Nothing below may be adjusted after the freeze commit; a change
requires a new family identifier and preregistration.

## Question

Can any one of four pinned single-model replacements rescue at least two of the final
frontier's residual technical-term misses on one fixed 48-row screen, without activating
a taught surface on a negative or making general96 U-WER more than `.0035` worse than
v3 on the same G16 rows?

The frontier verification reports `recall_hits=295`, `term_misses=51`, and
`uwer_general=.030725` (`.build/autoresearch/metrics.txt:3,13-16`). Wave 0 found the
pilot blocked only because its fixed manifest was not yet derivable: R16 had 4/16,
N16 covered 1/7 standing surfaces, and G16 had 0 noise-condition rows
(`.build/asr-research/next/single-model/single-model-replacement-screen/wave0/verdict.md:3-16`).
The cached frontier rows and locally retained fresh-shard fire audio now permit an honest
48-row screen, while the missing noise condition remains an explicit limitation.

## Hypothesis

H1: at least one pinned replacement has different acoustic capacity from v3 and produces
`safe_residual_rescues ≥ 2` on distinct R16 rows, while `negative_false_terms = 0` and
`G16_uwer(candidate) − G16_uwer(v3) ≤ .0035`.

H0: every candidate rescues at most one R16 row, activates a taught surface on at least
one N16 row, or exceeds the fixed G16 non-inferiority margin.

## Inputs (sha256)

- `.build/autoresearch/jargon.2.results.jsonl` — 456 frontier rows; bench metadata
  `started_at=2026-09-02T12:47:10Z`, manifest `1b79fe505d7e99e0bf65ec5da4aa6f17d1320ad70cebfe262e4fdd0d332e60af`;
  `43c6593e29214bc4433472a625dff1e264b5864102a3221f82538ac73c7b61a8`.
- `.build/autoresearch/general.results.jsonl` — v3 general96 outputs used to score the
  selected G16 incumbent baseline; `73b4be67aab45da787add8c9e4b4beadeb45326904b0dded57be6e95d21357e1`.
- `.build/autoresearch/metrics.txt` — frontier metrics, including 295 hits and 51 misses;
  `faf454d338b6baf4e30dcd108249d04474c9ccbaa2d07096b1f46efe440d3d4f`.
- `bench/autoresearch/score_v5.py` — scorer; `bcd5c3fde5a2d5d9c2cdabdf59fe561ce03e9f7d0b522a435b6cf1f1a19e25de`.
- `bench/src/voiceour_bench/metrics.py` — exact-term and U-WER implementations;
  `307eb4f113bda8e72faa513fce4885befde425ed7a80036deab6354e8a50a539`.
- `bench/autoresearch/jargon.terms.json` — 173 positive-row canonicals, 346 positives, 110 negatives;
  `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`.
- `benchmarks/data/jargon/manifest.jsonl`; `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`.
- `bench/autoresearch/corpus.manifest.jsonl` (general96);
  `885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749`.
- Fresh fire manifests: `.build/asr-research/three-bets/holdout-earnings22/manifest.jsonl`
  `f68cceb4a41dc0a53964876d5f697925b1e72afb8e2c7d7b4b363880ac9e4817`;
  `.build/asr-research/three-bets/holdout-earnings22-diverse/manifest.jsonl`
  `4042f6b59a655df7250757330cf00ad7d932338bb9404b39d4231be6e5e2ca03`;
  `.build/asr-research/three-bets/holdout-peoples-speech/manifest.jsonl`
  `ade4139e607091a6ae49b83451e99dc2550a3eca80d7e0da74f45ae177f4fa28`;
  `.build/asr-research/three-bets/holdout-peoples-speech2/manifest.jsonl`
  `42054fcb8d3a3318eb2fc1d011e55b12a7c70ad7e39b29552181a625a269c2ff`.
- Fire outputs under those directories: Earnings22 `pass-A1`/`pass-A2`
  `804c919b81219050f07f6267701ed022c7e0c800a1868e9caf5e41a297dfb533` /
  `19cdd5aa79b67677a6efc274662ef9c3306e30d3b7e3570aeb77daa8682d5a63`;
  diverse `stage-A1`/`A2`, both
  `673b473f08773ca51e7943f87d38d61d931453e04b9643d7e1af3f82649ebf37`;
  People's Speech shard 0, both
  `6afd41a532e46b07d734d963dae73ea0ef973c5e2ccac78f451b53c85a79f971`;
  shard 2, both `4b0415b9f3a5fa1540aea49ae8b8e1a8fe549ed253a1426f05963322caeea7af`.
- `.build/asr-research/next/single-model/single-model-replacement-screen/wave0/slice-inventory.json`;
  `9190d6ecb58ff7af3c19c40019274cb771b0562cd4c82f4773113c14be3ba820`; and
  `.build/asr-research/next/single-model/single-model-replacement-screen/wave0/verdict.md`;
  `4deb54f218228f91e174161281c0cdbcaaa27c40792a263d2af85af02d0baa20`.
- `research/next-program.md`; `7ae119c644b01e0d3c3718ab6bd5b4d5ceb6e462214339f7f417d8a03d15a98f`.
- `/Users/vlad/Documents/ObsidianVault/projects/voiceour/concepts/single-model-replacement-screen.md`;
  `672b2a36902910208515944e510995bc8bf7b917ca618141d3aec3bed84eff6c`.

All paths are relative to `/Users/vlad/Desktop/voiceoour` unless absolute. The 48 audio
files below exist locally and their bytes were checked against the listed SHA-256.

## Part 1 — cached, CPU-only manifest freeze

### R16 selection (fixed)

Recompute the 51 misses, do not trust the printed examples. The rule is verbatim:
“case-sensitive canonical containment over non-negative rows of the frozen terms file”
(`score_v5.py:7-8`). Specifically, include every non-negative term row with a nonempty
`canonical` whose cached `final_text` does **not** satisfy `contains_exact_term`
(`score_v5.py:183-203`). That predicate is exact and case-sensitive; it adds a negative
lookbehind/lookahead only when the corresponding canonical endpoint is alphanumeric or
underscore, escapes the canonical, and performs Unicode regex search
(`metrics.py:382-389`). This deterministically reproduces 295 hits and 51 misses.

Stratify the misses by `domain`: guarantee one per domain, then allocate the remaining 11
proportionally to remaining counts by largest remainder (domain tie-break), yielding
apple/cloud/dataweb/langs/security `3/4/1/4/4`.
Within each sorted-domain pool, draw without replacement using
`numpy.random.default_rng(20260830).permutation`; use one RNG in alphabetical domain
order. The selected rows are:
All R audio paths are `benchmarks/data/jargon/audio/$ID.wav`, with `$ID` equal to that
row's complete printed ID; the manifest supplies each reference and digest below.

- R01–R03: `jg_0235_apple_mmap` / `mmap` / `7c666f7c8af22b91f115e78e8eefb0fbfa3d8df6c05758cfaf10663bfc1c0a40`; `jg_0242_apple_epoll` / `epoll` / `7fce20c25e3373fa1cce3b21f6849210d981ff36d06f2934fc48272123454f10`; `jg_0234_apple_mmap` / `mmap` / `c20226963f66261bb064d62dc9db71015b1869a56725955a8ffe4a992eb62941` (apple).
- R04–R07: `jg_0040_cloud_iam` / `IAM` / `6b59472126e12da84297aa9961b14ed2157d0587023c9cfb8add8886b1f36512`; `jg_0020_cloud_nginx` / `nginx` / `2c3b55d35181a30a5544d8bc40570ede529a860d474df951db971d130665993d`; `jg_0021_cloud_nginx` / `nginx` / `68fc0effcde02f345892c0c0def80af559ca0388ad33d23f5050e7745baaa542`; `jg_0003_cloud_kubeadm` / `kubeadm` / `86e401e30603eefa420dc48257ace3adbe0046f92a7ec38f2853cc011fe28e1a` (cloud).
- R08: `jg_0334_dataweb_cudnn` / `cuDNN` / `63e838a34b408240dee1387cfb952ffdf98cadb2e10a624ceb9bed04b4d64028` (dataweb).
- R09–R12: `jg_0194_langs_uv` / `uv` / `67e532098dd8b3032a97f00edbd29a29916f81d8e275c10197b629bd7d0ccf90`; `jg_0147_langs_cargo` / `Cargo` / `36cd0e3277ccb68b33798496dc3e69e43e17695904a8f9ccb562c8557ab5c868`; `jg_0180_langs_c` / `C#` / `51cadcd59d8cd90a4fc95e6e51d8139c7b1cdbfb9603d4c0664d1e7eb813056d`; `jg_0151_langs_deno` / `Deno` / `e2af210d486520223989f93b8c33453828bd7be62f0e081293db7af01af052c6` (langs).
- R13–R16: `jg_0113_security_tcpdump` / `tcpdump` / `b9a28e28e7378fc324e630b2f7ae1011546a80fbdb85c0fb5e0274984435510c`; `jg_0104_security_nmap` / `nmap` / `08883c02a594f13b9e425d91b144d9444d2eca1010897152dfc6291029744e84`; `jg_0112_security_tcpdump` / `tcpdump` / `9d4094955f004558f1050a40bd1b6276e8584bf23cb0a6a6112508a4be216881`; `jg_0101_security_ed25519` / `Ed25519` / `46a99f7ae569d25258e20c12a8a3f718ef2479ac91c24ce36a08cfa539a05e82` (security).

### N16 selection (fixed)

Fresh-shard rows that actually produced a standing fire come first. A fire means the
A-stage output contains the case-sensitive exact taught surface and its reference does
not. Duplicate A1/A2 evidence selects the row once. All seven local fire audio files
exist. There is no local fresh fire for `C++`/CI/secret or `queue`/`kqueue`; N08–N16
therefore use pinned jargon negatives, with N16 covering spoken “queue.” Every N row is
scanned against all 173 unique positive-row canonicals; the named surface records the
specific fire it guards, not a reduced scan set.

- N01 `earnings22-4432298-136` — `Credit Swift`; `.build/asr-research/three-bets/holdout-earnings22/audio/earnings22-4432298-136.wav`; `d8036b3b7fef5a3c75e032d42a9abc49ee506014cd27b99d8a03cd724e3b557c`
- N02 `earnings22b-4483338-151` — `IAM`; `.build/asr-research/three-bets/holdout-earnings22-diverse/audio/earnings22b-4483338-151.wav`; `86cf0dafab115c6b632007a2d3503e99fed0ecbb3c52fda1deffc5bd47a43542`
- N03 `earnings22b-4483338-30` — `IAM`; `.build/asr-research/three-bets/holdout-earnings22-diverse/audio/earnings22b-4483338-30.wav`; `4df2e1801f59ce0fea1c1e6eda8539faa3c077814bb93c7e72b3b90e820d80fc`
- N04 `earnings22b-4483338-218` — `IAM`; `.build/asr-research/three-bets/holdout-earnings22-diverse/audio/earnings22b-4483338-218.wav`; `5ee19cc1858ef0e21f0621428eed0859206f23f769f21b68679e9e318f18441e`
- N05 `earnings22b-4485244-146` — `CALayer`; `.build/asr-research/three-bets/holdout-earnings22-diverse/audio/earnings22b-4485244-146.wav`; `f15d1669201892bcdcf0de60971e5cf847364a475964b8eb06918466edf09f61`
- N06 `peoples-clean0-3343` — `Redis`; `.build/asr-research/three-bets/holdout-peoples-speech/audio/peoples-clean0-3343.wav`; `adee40356b4c98b789e3e931b9eeac3b6ef6835fee147490445af4bb4773838b`
- N07 `peoples-clean2-2592` — `runc`; `.build/asr-research/three-bets/holdout-peoples-speech2/audio/peoples-clean2-2592.wav`; `2f81e4dced660c5fdd97321aad1139ddf7d06e8839596d89f21abb244c44cfdc`
- N08 `jg_0347_negative_the_old_gate_had_rust_all_along_`; `benchmarks/data/jargon/audio/jg_0347_negative_the_old_gate_had_rust_all_along_.wav`; `81070e662f95c17b426f796fda2eee4b705f78e8ee3ea7a53b596266304601e2`
- N09 `jg_0348_negative_a_swift_bird_crossed_the_garden_`; `benchmarks/data/jargon/audio/jg_0348_negative_a_swift_bird_crossed_the_garden_.wav`; `544bf6e894ce2ffbc00fe884d3f1d597b9c26bfff840ae396f2e3f1475de67c1`
- N10–N16 IDs/hashes, in order: `jg_0349_negative_the_metal_spoon_felt_cold_agains` / `5cdd220b9bf9704566490ee3820f1e43b6d4865fa681ad657c08f7200fb49fa5`; `jg_0350_negative_the_cargo_was_unloaded_at_the_ha` / `610eb26e0fcf16c6f8c944f64f4e9c2cde8a73b74ae1e0e70e041a4c91a7ae3e`; `jg_0358_negative_the_python_rested_quietly_beneat` / `550995baa7a3e38420fb9470582919e7bb8cbedce06ef5d0a91d9b368f6c13e6`; `jg_0359_negative_please_react_calmly_when_the_chi` / `2a89b61e57cf54562094f128bc60ffd99ab8959eba9c705fa923f26b4da70a3e`; `jg_0360_negative_a_small_node_on_the_wooden_branc` / `88c2b733bd892f2a5526988a0001cbb5cb83f272086faa842c53661c8630d9a9`; `jg_0366_negative_i_cannot_commit_to_dinner_until_` / `210fec84a2fee20f7604db3ec654eef1ac93c3787e614de2eec950a0472f3b80`; `jg_0385_negative_we_waited_in_the_queue_outside_t` / `49741a125c802c737be4c6f31cb8ef9dcaed89ade7908f81981d7d7b54e968c9`. Each path is `benchmarks/data/jargon/audio/$ID.wav`; N16 guards `queue`/`kqueue`.

### G16 selection (fixed)

Stratify general96 by `source`: guarantee one per source, then allocate the remaining 13
proportionally by largest remainder (source tie-break), yielding FLEURS/LibriSpeech
clean/other `6/5/5`.
Within each sorted-source pool use a fresh `numpy.random.default_rng(20260830)`, sources alphabetical. This sample has no
controlled noise-condition labels because general96 has none; that Wave 0 requirement is
unmet, recorded rather than silently imputed.

- G01–G06 FLEURS: `000021` / `4474304761819edbfa603c0660c6d4ec71d0552083f1db36578180f67d50ad91`; `000016` / `c45ec6f59ccd1bfa03af1e9f49882630b5cad6533bd47aaa4d328d070b61c1ab`; `000001` / `7835bd6ffb54ce38a2a9bcde3905ba424faed94d50a474f21a9cbe9209b869df`; `000017` / `768da07acfa8ef8f0e54631b4d0595ab85ceb3d42eca99a2c158a8a5e82658ac`; `000049` / `6bec9c0a7a0e9d7883940892266e477bd915a6724ac883a8e81d853d1144dacc`; `000004` / `f4e95852e336403001191b6dbfc9f00c5263cea304c10761608d6d5fce23da3f`. IDs are `fleurs-en_us-test-$SUFFIX`; paths `benchmarks/data/fleurs/audio/en_us_test_$SUFFIX.wav`.
- G07–G11 LibriSpeech clean: `000005` / `cdc2be06bf8e12ce0ff632945f8ed3e5b0976597681d73cbd0767df8b44f2acf`; `000103` / `35f928654a2e6d079ff1c9256f10116e23a02cfd5b2eda66c2f46dbba452bcac`; `000095` / `a73986d579b7d6fa5446aeb155dac14171a5b620646fbd129af0ee483a3926a1`; `000030` / `1e929f684833d4912c6e0ccba95336341c45ae8de7147bb89a6b7b3c500f56d9`; `000100` / `93a2bd20b1a0d695a7c8d932446da11dfe2021d45ecabda216e13cfb1720039c`. IDs are `librispeech-test.clean-$SUFFIX`; paths `benchmarks/data/librispeech/audio/test_clean_$SUFFIX.wav`.
- G12–G16 LibriSpeech other: `000022` / `87772104537300ab2ad8de1e143370b5d4beaf18ab302fd29d18df53a6753ac5`; `000024` / `91e08cf599270d8922ace14dd8ecc18edee0dde7096ea56f0c0dcc834430ab93`; `000014` / `7b875d745cedfebce34ed13849fdcf74937e6c7e05c591adae806d68ffd8d9eb`; `000057` / `da9a5cfc01d99f8359222e94ec9eb0d06280554b416f4e91affe795ba59658c6`; `000047` / `7a911b787399ebd5f4251d6ebdfd2fb80a5bc0844b938dfbf171aa62278560a2`. IDs are `librispeech-test.other-$SUFFIX`; paths `benchmarks/data/librispeech/audio/test_other_$SUFFIX.wav`.

The canonical run manifest serializes one compact sorted-key JSON object per row with
`slice,slot,id,audio_path,audio_sha256,reference` plus R `canonical,stratum`, N
`guard_surface`, or G `stratum`, UTF-8, no spaces, newline after every record. Its frozen
expected SHA-256 is `f0682f70bb373beaab8aea30562a72844613293088d9fe1c3c44cb9a11472a15`.
The run must reproduce this digest before any candidate contact.

## Part 2 — parent-serialized, exclusive hardware and downloads

Part 2 is blocked now: `bench/.venv` lacks `torch`, `mlx`, `nemo`, `transformers`,
`qwen_asr`, and `moshi_mlx`; Cohere is gated and has no admitted CoreML artifact. The
parent alone creates isolated environments, downloads exact revisions, records every
artifact SHA-256/byte count/licence, stops Voiceour, and executes candidates serially.
Each candidate gets exactly one pass over the same 48 rows; English forced, no timestamps,
prompt, glossary, bias, or postprocessing, and final text only. Configuration is fixed
below; Kyutai alone retains its publisher audio-token sampler, seeded 20260830.

The exact acquisition/install/decode specifications are:
Commands set `RUN1=/Users/vlad/Desktop/voiceoour/.build/asr-research/next/single-model/single-model-replacement-screen/wave1/run1`; each candidate directory and environment are `$RUN1/{qwen,kyutai,canary,cohere}` and `$RUN1/{qwen,kyutai,canary,cohere}/env`.

1. **Qwen3-ASR 0.6B** — `Qwen/Qwen3-ASR-0.6B` revision
   `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`. Python 3.12; `qwen-asr==0.0.6`, locked
   dependencies; `huggingface-cli download Qwen/Qwen3-ASR-0.6B --revision 5eb144179a02acc5e5ba31e748d22b0cf3e303b0 --local-dir $RUN1/qwen/model`.
   Install: `uv venv --python 3.12 $RUN1/qwen/env && uv pip install --python $RUN1/qwen/env/bin/python 'qwen-asr==0.0.6' 'torch==2.14.0'`.
   Decode: `$RUN1/qwen/env/bin/python $RUN1/decode_qwen.py --model $RUN1/qwen/model --manifest $RUN1/pilot-manifest.jsonl --output $RUN1/qwen/rows.jsonl --device mps --dtype float32 --language English --max-new-tokens 256 --batch-size 1`; internally `from_pretrained` then one `transcribe` per row.
2. **Kyutai STT 1B MLX** — `kyutai/stt-1b-en_fr-mlx` revision
   `2b995724eef1e964b7ccb6a762b35a665c4abe0d`. Python 3.12; `moshi_mlx==0.2.12` plus
   publisher-script dependencies, locked; `huggingface-cli download kyutai/stt-1b-en_fr-mlx --revision 2b995724eef1e964b7ccb6a762b35a665c4abe0d --local-dir $RUN1/kyutai/model`.
   Install: `uv venv --python 3.12 $RUN1/kyutai/env && uv pip install --python $RUN1/kyutai/env/bin/python 'moshi_mlx==0.2.12' 'huggingface_hub==1.29.0' 'numpy==2.5.2' 'sentencepiece==0.2.2' 'sounddevice==0.5.6' 'sphn==0.2.1'`.
   Decode: `$RUN1/kyutai/env/bin/python $RUN1/decode_kyutai.py --model $RUN1/kyutai/model --manifest $RUN1/pilot-manifest.jsonl --output $RUN1/kyutai/rows.jsonl --sample-rate 24000 --max-steps 4096 --text-top-k 25 --text-temperature 0 --audio-top-k 250 --audio-temperature 0.8 --seed 20260830`. The local-only publisher algorithm uses `sphn.read(..., sample_rate=24000)` and seeds MLX before model creation; any nondeterministic runtime evidence kills, never seed-tunes.
3. **Canary 180M Flash** — `nvidia/canary-180m-flash` revision
   `b12ab418510d093e83890178fd0e8b0d0f7918a6`. It requires an exclusive NVIDIA Linux
   host. Python 3.13; NeMo ASR and torch locked; `huggingface-cli download nvidia/canary-180m-flash canary-180m-flash.nemo --revision b12ab418510d093e83890178fd0e8b0d0f7918a6 --local-dir $RUN1/canary/model`; verify LFS SHA-256 `7b97de18b718ef01bf3398715ce8d18486c4d83961e230230b26f5712e112675`.
   Install on the NVIDIA host: `uv venv --python 3.13 $RUN1/canary/env && uv pip install --python $RUN1/canary/env/bin/python 'nemo_toolkit[asr,cu13]==3.0.0' 'torch==2.12.0+cu132' --extra-index-url https://download.pytorch.org/whl/cu132`.
   Decode: `$RUN1/canary/env/bin/python $RUN1/decode_canary.py --model $RUN1/canary/model/canary-180m-flash.nemo --manifest $RUN1/pilot-manifest.jsonl --output $RUN1/canary/rows.jsonl --batch-size 1 --beam-size 1 --pnc yes --timestamps no --source-lang en --target-lang en`.
4. **Cohere Transcribe** — `CohereLabs/cohere-transcribe-03-2026` revision
   `b1eacc2686a3d08ceaae5f24a88b1d519620bc09`. Python 3.12; model-card `transformers`,
   `torch`, and audio dependencies locked; after gated approval, `huggingface-cli download CohereLabs/cohere-transcribe-03-2026 --revision b1eacc2686a3d08ceaae5f24a88b1d519620bc09 --local-dir $RUN1/cohere/model`.
   Install: `uv venv --python 3.12 $RUN1/cohere/env && uv pip install --python $RUN1/cohere/env/bin/python 'transformers==5.16.1' 'torch==2.14.0' 'soundfile==0.14.0' 'librosa==1.0.0'`.
   Decode: `$RUN1/cohere/env/bin/python $RUN1/decode_cohere.py --model $RUN1/cohere/model --manifest $RUN1/pilot-manifest.jsonl --output $RUN1/cohere/rows.jsonl --device mps --dtype float32 --language en --num-beams 1 --do-sample false`. Use only local revision code; no API or community CoreML substitute. It stays blocked absent an executable gated local API.

A runtime that cannot execute its command on admitted exclusive hardware is **blocked**,
not assigned a score. No MPS/CUDA/CoreML result implies Voiceour product feasibility.

## Scoring and endpoints (fixed)

Candidate output is used verbatim as `final_text`; no Voiceour glossary repair is applied.
`safe_residual_rescues` is the number of distinct R16 rows whose output satisfies the
same `contains_exact_term(final_text, canonical)` predicate, **provided globally** that
`negative_false_terms=0` and the candidate's pooled G16 U-WER is no more than `.0035`
above v3. The v3 G16 baseline is frozen at 19 errors / 799 reference words =
`.023779724655819776`; hence the candidate must satisfy `G16_uwer ≤ .027279724655819776`.
U-WER is the repository's pooled Whisper-English-normalized `jiwer.process_words` result
(`metrics.py:67-80`), not a mean of row WERs.

`negative_false_terms` is the number of N16 rows on which any of the 173 unique positive
canonicals is exact-case present in candidate output and not exact-case-insensitive present
in the row reference, matching `score_v5.py:46-71`. N guards are row-level: multiple
surfaces on one row count once. `error_rows` counts absent/failed outputs. Secondary only:
raw R16 rescues before global safety/NI gating, G16 numerator/denominator, per-source
G16 errors, and the exact activated surfaces.

- **Primary endpoint:** `safe_residual_rescues`, always reported with
  `negative_false_terms` and G16 U-WER delta.
- **Meaningful effect / pass:** `safe_residual_rescues ≥ 2` and
  `negative_false_terms = 0`, `G16_uwer_delta ≤ +.0035`, `error_rows = 0`.
- **Kill:** for a completed candidate, fewer than 2 safe residual rescues, any N16 taught-
  surface activation, G16 delta above `+.0035`, any error row, or nondeterministic Kyutai
  sampling evidence kills that candidate. If all completed candidates die, or the others
  remain runtime/admission-blocked, the track stops and no candidate enters Wave 2.

No model or operating threshold is learned. The whole selection budget is the four pinned
candidate/configuration pairs above. The operating point is the publisher's fixed greedy
configuration; there is no post-measurement choice.

## Uncertainty

The 48 rows are the inference units because no speaker/session clusters exist for synthetic
R16/G16 and the available fresh negatives span unrelated source recordings. Report
percentile 95% intervals with B=10,000 and seed 20260830, resampling rows within each
slice independently and preserving 16/16/16, for R rescue rate and pooled G16 U-WER
(recompute pooled errors/words on each draw). Report the exact Clopper–Pearson 95% upper
bound for `negative_false_terms/16` when zero: `1 − .025^(1/16) =
.20590721420782276`, the two-sided zero-count bound. For each candidate versus v3 on G16,
run an exact paired sign-flip permutation over the 16 row-level error-count differences (`2^16` assignments),
reporting the two-sided p-value; the `.0035` NI bar, not p-value, decides pass.

No random split is drawn, so repeated random splits do not apply. Candidate-to-candidate
comparisons are descriptive only; if reported, use the same exact paired sign-flip test
on R rescue indicators and G row error differences, with no winner selected by p-value.

## What this pilot cannot show

R16 and nine N rows are single-voice synthetic speech; G16 has no controlled noise label;
seven N rows are prior fresh-shard development evidence, not a sealed holdout. Sixteen
negatives cannot establish product-scale zero-fire risk even with its exact binomial bound.
The pilot does not show real-speaker technical recall, multilingual retention, latency,
RTFx, footprint, installed bytes, cold start, packaging, sidecar protocol compatibility,
or a CoreML/MLX product adapter. A pass only licenses the canonical Wave 2 harness; later
promotion still requires a new speaker/session-disjoint sealed holdout under the fresh-
holdout rules.

## Artifacts

Root: `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/single-model/single-model-replacement-screen/wave1/`.
Wave level: `prereg.md` (this file plus freeze commit) and `verdict.md`. `run1/` contains
`manifest.json` (all required program keys, input digests, candidate revisions, environment,
prereg commit, and `pilot_manifest_sha256`), `pilot-manifest.jsonl`, `command.txt`,
`metrics.jsonl`, `rows.jsonl`, `selection.py`, `score.py`, and per-candidate directories
with `uv.lock`, acquisition manifest, artifact digests/bytes/licence, decode script,
stdout/stderr, and `rows.jsonl`. This non-harness run never writes `metrics.txt`.

## Stop rule

Part 1 runs once; manifest digest mismatch stops the track before download. Part 2 runs
each admitted candidate once, parent-serialized on exclusive hardware. No retry for a
quality failure and no tuning against these rows. One implementation defect may be fixed
and that candidate rerun once, with the defect and invalidated output recorded; a second
defect stops that candidate. A failed pilot stops the track for that candidate, and no
full harness is run unless the frozen meaningful-effect and all hard guards pass.
