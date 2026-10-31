# Real-speaker technical-speech mining pipeline

Mines real conference speech for utterances containing Voiceour's 173 jargon
canonicals, to build a real-speaker counterpart to the synthetic screen corpus.

Six stages, one script each, every stage writing `manifest.json` +
`command.txt` next to its outputs:

| stage | script | input -> output |
| --- | --- | --- |
| 1 | `fetch.py` | direct media URL -> `raw/<talk>.av1.webm` (+ bytes, sha256, MB/s, licence) |
| 2 | `extract.py` | media -> `audio/<talk>.16k.mono.wav` (static-ffmpeg, pcm_s16le) |
| 3 | `segment.py` | wav -> `vad/segments.jsonl` + `vad/segments/*.wav` (silero-vad, 1-15 s, 0.3 s pad) |
| 4 | `transcribe.py` | segments -> `asr/hypotheses.jsonl` (NeMo parakeet-tdt-0.6b-v3, CUDA, word timestamps) |
| 5 | `mine.py` | hypotheses + `jargon.terms.json` -> `terms/candidates.jsonl` + `terms/density.json` |
| 6 | `report.py` | all manifests -> `report/report.md` |

`run_all.sh <talk-id> <media-url> [index-url]` runs all six in order and
refuses to start stage 4 if another process holds VRAM.

## Running

Everything runs inside the existing `envs/nemo` uv project — no new env is
needed, all dependencies (torch cu128, nemo_toolkit 3.0.0, silero-vad,
static-ffmpeg, soundfile, rapidfuzz) are already in its lock:

```sh
export PATH="$HOME/.local/bin:$PATH" UV_CACHE_DIR=/srv/devbox/cache/uv \
       UV_PYTHON_INSTALL_DIR=/srv/devbox/research/voiceour/envs/pythons \
       HF_HOME=/srv/devbox/cache/hf
cd /srv/devbox/research/voiceour/envs/nemo
uv run python /srv/devbox/research/voiceour/mining/fetch.py --help
```

Stage 4 needs the 8 GB GPU **alone**: parakeet peaks at 4978 MiB and a
concurrent training process pins ~3 GB, which makes the model load OOM.
Coordinate before running it.

## Source selection

FOSDEM archive layout: `https://video.fosdem.org/<year>/<room>/<slug>.av1.webm`.
Prefer `.av1.webm` (41 MiB for a 13 min talk); the sibling `.mp4` is the
stream mezzanine at ~10x the size. Direct URLs 302-redirect to a mirror;
`fetch.py` follows and records the resolved URL. Rooms are numeric codes, not
devroom names — list a room index and grep slugs to find a devroom.

**Licence:** FOSDEM recordings are CC BY 2.0 Belgium. Any derived audio,
segments, or transcripts must keep FOSDEM + speaker attribution and the
licence notice. `fetch.py` stores the notice in the stage manifest.

## What the smoke run established

One talk (FOSDEM 2025 event 4189, "Writing a Kubernetes controller, but in
Rust", 12.6 min) end to end on the RTX 2070 SUPER:

- **Throughput is a non-issue.** RTFx 45.3 fp32 batch 8, peak 4978 MiB of
  8192; one hour of speech costs ~1.3 GPU-minutes. VAD runs 179x realtime,
  ffmpeg decode 1668x, mining 2593x.
- **Term density is the binding constraint.** 15 (utterance, canonical) exact
  hits in 12.6 min = 71/talk-hour raw, but 12 of those 15 are the English
  homographs `Go` and `Rust`; only `Kubernetes` x3 is unambiguous, i.e.
  14/talk-hour. Reaching 1,500 term utterances needs ~105 talk-hours on the
  unambiguous basis (~21 h if homographs are adjudicated as technical).
- **The ASR hides the terms you want.** The transcript of a Kubernetes/Rust
  talk contains "kubernetes" 3x, "CRD" 2x, "k8s" 1x, and zero
  cargo/tokio/serde/trait. Jargon is mangled into ordinary words ("custom
  resource in the reconcile" -> "customer resource in the RC can sell"), so
  exact matching on hypotheses systematically under-counts exactly the terms
  glossary work targets.
- **String similarity cannot recover mishearings.** `partial_ratio >= 90`
  yielded 18 hits, 17 of which are scorer artifacts (a window that is a
  substring of the canonical scores 100: `code` in `Xcode`). Recovering
  "cube control" -> `kubectl` needs a phonetic matcher (G2P + phoneme edit
  distance), not character similarity.
- **parakeet degenerates on non-speech.** 3 of 147 utterances emit `⁇` loops
  at up to 127 tokens/s (2540 of 4367 emitted tokens). `mine.py` excludes
  utterances with >=50% `⁇`; without that the fuzzy pass manufactured 4510
  spurious hits.

Consequence for corpus design: mine talk *slides/captions* or curated
term-dense sources for candidate discovery, use ASR only to locate the audio
window, and budget human adjudication for homographs.

## Notes on `jargon.terms.json`

The frozen taxonomy has **no `heard_as`/alias field** — 456 entries carry only
`{canonical, domain}` (346) or `{domain}` (110 negatives), giving 173 distinct
canonicals over 5 domains. `mine.py` therefore derives separator/case surface
variants from each canonical (so `AES-GCM` matches "aes gcm"/"aesgcm", `X.509`
matches "x 509") and accepts an external table via
`--aliases '{"kubectl": ["cube control", ...]}'` for when heard-as forms exist.
Canonicals containing `+`/`#` (`C++`, `C#`) are matched literally, since their
alphanumeric run is a bare `c`.
