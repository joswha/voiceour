# Preregistration amendment — single-model-replacement-screen, Wave 1b

Family identifier `single-model-replacement-screen/wave1b`. Supersedes only the
manifest-digest clause of `single-model-replacement-screen-wave1.md` (frozen at `898262c`,
sha256 `f8d087641079d8b9a1a492ef7dfa6e70b6175f4e36fc75594f164c7e55f4cf8e`); every other
section of that file — the 48-row design, the R16/N16/G16 draws with seed 20260830, the
Part 2 candidate protocol, scoring, endpoints, bars, kill rule, uncertainty — is carried
over unchanged and is not restated here.

## Reason for amendment (recorded before any candidate is contacted)

The Wave 1 Part 1 run (`.build/asr-research/next/single-model/single-model-replacement-screen/wave1/run1/`)
reproduced every selection number the original preregistration fixed — 295 hits / 51
misses from `.build/autoresearch/jargon.2.results.jsonl`, the R16 domain allocation
3/4/1/4/4, the G16 source allocation 6/5/5, all seven fresh-shard fires, all 48 audio
files present and byte-identical to the printed digests, and the v3 G16 baseline of
19 errors / 799 words — but the original text pinned a sha256 of the pilot-manifest file
(`f0682f70…`) without specifying the file's serialization or the guard-surface values of
slots N08–N15. No serialization the run could enumerate (792,000 candidates) reproduced
that digest. The defect is in the freeze document, not in the row set, and the stop rule
of the original file correctly blocked Part 2. This amendment replaces the unspecifiable
file digest with committed, byte-level pins of the generator and its output.

## Pins (fixed)

- Generator, committed verbatim as it ran: `research/prereg/tools/replacement_screen_selection.py`,
  sha256 `973b666086d56278324eb51c8e3f8d1b8a8dd40b9f60e1e17ad06e01755df99b`.
- Frozen pilot manifest, committed verbatim as the generator wrote it:
  `research/prereg/tools/replacement-screen-pilot-manifest.jsonl`, 48 rows,
  sha256 `6228b4cd384f36e62b9e0973ee2ea2119a9d9174bad6b573c657852d5a7db649`.
  Fields per row: `slice`, `slot`, `id`, `audio_path`, `audio_sha256`, `reference`,
  `canonical` (R16 target or N16 guard surface; empty for G16), `stratum`.
- Row identity for Part 2 is the committed manifest; a candidate run's row set must equal
  it exactly by `id` and `audio_sha256`, or the run is void.

## Coverage the manifest achieves (fixed facts, from the run)

- R16: 16 residual-miss rows — apple 3, cloud 4, dataweb 1, langs 4, security 4
  (mmap ×2, epoll, IAM, nginx ×2, kubeadm, cuDNN, uv, Cargo, C#, Deno, tcpdump ×2, nmap,
  Ed25519).
- N16: 7 fresh-shard real-speech fire rows (Credit Swift; IAM ×3; CALayer; Redis; runc)
  plus 9 synthetic ordinary-language negatives (Rust, Swift, Metal, Cargo, Python, React,
  Node, commit, kqueue). Standing surfaces covered: 6 of 7; `C++` for spoken "CI"/"secret"
  has no local audio and is recorded as uncovered.
- G16: FLEURS 6, LibriSpeech clean 5, LibriSpeech other 5; v3 baseline 19 errors / 799
  reference words = `.023780`; the G16 ceiling under the +.0035 margin is `.027280`.

## What remains blocked

Part 2 is unchanged and remains parent-serialized, exclusive-hardware work requiring
downloads and toolchains that are not installed: isolated pinned runtimes for Qwen3-ASR
(torch), Kyutai STT (mlx / moshi_mlx 0.2.12), Canary 180M Flash (NeMo), and an executable
local artifact or admitted API for Cohere Transcribe. The parent creates each environment,
records the exact install and decode commands, and runs one pass over the committed
48-row manifest per candidate. Nothing in this amendment lowers a bar.
