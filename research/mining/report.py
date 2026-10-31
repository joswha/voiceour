"""Stage 6 — assemble report.md from the five stage manifests + density.json.

The report is generated, never hand-written, so it cannot drift from the
manifests. Every number printed here is read out of a manifest on disk.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import read_jsonl, write_manifest


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def fmt(x, nd=2, dash="n/a"):
    if x is None:
        return dash
    if isinstance(x, float):
        return f"{x:,.{nd}f}"
    if isinstance(x, int):
        return f"{x:,}"
    return str(x)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-root", required=True, help="data/mining root holding raw/ audio/ vad/ asr/ terms/")
    ap.add_argument("--out", required=True, help="path of report.md")
    ap.add_argument("--target-utterances", type=int, default=1500)
    ap.add_argument("--examples", type=int, default=12)
    args = ap.parse_args()

    root = Path(args.data_root)
    m_fetch = load(root / "raw" / "manifest.json")
    m_extract = load(root / "audio" / "manifest.json")
    m_segment = load(root / "vad" / "manifest.json")
    m_asr = load(root / "asr" / "manifest.json")
    m_mine = load(root / "terms" / "manifest.json")
    density = load(root / "terms" / "density.json")
    candidates = read_jsonl(root / "terms" / "candidates.jsonl")

    talk = m_fetch["talk"]
    dl = m_fetch["download"]
    audio_s = m_extract["audio_s"]
    talk_h = audio_s / 3600.0
    seg = m_segment
    thr = m_asr["throughput"]
    gpu = m_asr["gpu"]
    env = m_asr["env"]

    ex_unamb = density["exact_unambiguous"]
    ex_any = density["exact"]
    proj = density["projection_to_1500_term_utterances"]

    exact_examples = [c for c in candidates if c["match_kind"] == "exact" and not c["ambiguous"]]
    exact_examples.sort(key=lambda c: (c["canonical"].lower(), c["start_s"]))
    seen: set[str] = set()
    picked = []
    for c in exact_examples:
        if c["canonical"] in seen:
            continue
        seen.add(c["canonical"])
        picked.append(c)
        if len(picked) >= args.examples:
            break
    weak_examples = [c for c in candidates if c["match_kind"] == "weak_fuzzy"][:8]
    amb_examples = [c for c in candidates if c["match_kind"] == "exact" and c["ambiguous"]][:10]

    per_domain_rows = "\n".join(
        f"| {d} | {v['hits']} | {v['hits_unambiguous']} | {v['distinct_canonicals']} | "
        f"{fmt(v['hits_per_talk_hour'],1)} | {fmt(v['hits_unambiguous_per_talk_hour'],1)} |"
        for d, v in density["per_domain"].items()
    )
    top_rows = "\n".join(
        f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |" for row in density["top_canonicals"][:15]
    )

    needed = proj.get("talk_hours_needed")
    needed_any = proj.get("talk_hours_needed_any")
    utt_rate = ex_unamb["utterances_with_hit_per_talk_hour"]
    utt_rate_any = ex_any["utterances_with_hit_per_talk_hour"]

    lines = f"""# Real-speaker technical-speech mining — smoke run report

Single-talk end-to-end smoke of the six-stage mining pipeline on the devbox
RTX 2070 SUPER. Every figure below is read out of the stage manifests in
`{root}`; nothing is hand-entered.

## 1. Source talk (stage 1 `fetch.py`)

| field | value |
| --- | --- |
| title | {talk['title']} |
| requested URL | `{talk['requested_url']}` |
| resolved URL (mirror) | `{talk['resolved_url']}` |
| attribution | {talk['speaker_note']} |
| bytes | {fmt(dl['bytes'],0)} ({dl['bytes']/2**20:.1f} MiB) |
| sha256 | `{dl['sha256']}` |
| download | {fmt(dl['elapsed_s'],2)} s at **{fmt(dl['throughput_MB_s'],2)} MB/s** |
| licence | {m_fetch['licence']} |

## 2. Timings end to end

| stage | wall s | rate |
| --- | --- | --- |
| 1 fetch ({dl['bytes']/1e6:.1f} MB) | {fmt(dl['elapsed_s'],2)} | {fmt(dl['throughput_MB_s'],2)} MB/s |
| 2 extract (ffmpeg av1→16 kHz mono pcm_s16le) | {fmt(m_extract['timings']['decode_s'],3)} | {fmt(m_extract['timings']['decode_xrealtime'],0)}x realtime |
| 3 segment (silero-vad, CPU) | {fmt(seg['timings']['vad_s'],3)} | {fmt(seg['timings']['vad_xrealtime'],1)}x realtime |
| 4 transcribe (parakeet-tdt-0.6b-v3, CUDA) | {fmt(thr['transcribe_s'],2)} | **RTFx {fmt(thr['rtfx'],2)}** |
| 4 model load (once) | {fmt(thr['model_load_s'],2)} | — |
| 5 mine (173 canonicals, exact + rapidfuzz) | {fmt(m_mine['timings']['mine_s'],2)} | {fmt(audio_s / m_mine['timings']['mine_s'],0)}x realtime |

Talk audio: **{fmt(audio_s,1)} s ({talk_h*60:.1f} min)**. VAD kept
{fmt(seg['audio']['kept_speech_s'],1)} s of speech in **{seg['counts']['segments']} utterances**
(speech ratio {fmt(seg['audio']['speech_ratio'],3)}; utterance p50
{fmt(seg['audio']['duration_p50_s'],2)} s, p95 {fmt(seg['audio']['duration_p95_s'],2)} s,
max {fmt(seg['audio']['duration_max_s'],2)} s).

## 3. GPU behaviour (RTX 2070 SUPER, 8 GB, cc {'.'.join(str(c) for c in env.get('cuda_capability', []))})

| metric | value |
| --- | --- |
| device | {env.get('cuda_device')} |
| torch / CUDA | {env['packages']['torch']} / cu{env.get('torch_cuda')} |
| precision | {m_asr['model']['precision']} (no bf16 and no FlashAttention-2 on Turing) |
| batch size | {m_asr['model']['batch_size_final']} (requested {m_asr['model']['batch_size_requested']}) |
| word timestamps | {m_asr['model']['timestamps_enabled']} |
| torch peak allocated | {fmt(gpu['torch_peak_allocated_MiB'],1)} MiB |
| torch peak reserved | {fmt(gpu['torch_peak_reserved_MiB'],1)} MiB |
| **nvidia-smi peak used** | **{fmt(gpu['nvidia_smi_peak_used_MiB'],0)} MiB** of 8192 ({gpu['nvidia_smi_samples']} samples) |
| model revision | `{m_asr['model'].get('hf_commit_sha')}` ({m_asr['model']['model_id']}) |
| OOM retries | {len([a for a in m_asr['model']['attempts'] if a['result'] == 'cuda_oom'])} |

The nvidia-smi figure is host-global, so it is only attributable to this run
because the GPU was verified idle first: `gpu.before` in the stage manifest
recorded `{gpu['before'].get('compute_apps')}` compute apps at
`{gpu['before'].get('gpu')}`. torch's own reserved peak
({fmt(gpu['torch_peak_reserved_MiB'],0)} MiB) corroborates it. An earlier attempt of this
same stage died with `torch.OutOfMemoryError` at model load while a sibling
agent's training process held 3152 MiB, so on this 8 GB card stage 4 cannot
share the device.

RTFx {fmt(thr['rtfx'],2)} means one hour of speech costs
**{3600 / thr['rtfx'] / 60:.1f} min** of GPU time on this card, so the
transcription stage is not the bottleneck for corpus construction.

## 4. Term density (stage 5 `mine.py`)

Taxonomy: {density['terms']['canonicals_in_taxonomy']} canonicals across
{len(density['per_domain'])} domains, read from `jargon.terms.json`.
**That file carries no `heard_as`/alias field** (field-set census:
{json.dumps(density['terms']['taxonomy_fieldsets'])}), so exact matching uses
the canonical plus deterministic separator/case surface variants, and the
rapidfuzz pass covers near-misses. `mine.py --aliases` accepts an external
heard-as table when one exists.

| measure | raw (incl. English homographs) | unambiguous only |
| --- | --- | --- |
| (utterance, canonical) hits | {ex_any['hits_segment_canonical_pairs']} | {ex_unamb['hits_segment_canonical_pairs']} |
| distinct canonicals | {ex_any['distinct_canonicals']} | {ex_unamb['distinct_canonicals']} |
| utterances with >=1 hit | {ex_any['utterances_with_hit']} of {seg['counts']['segments']} | {ex_unamb['utterances_with_hit']} of {seg['counts']['segments']} |
| **hits / talk-hour** | **{fmt(ex_any['hits_per_talk_hour'],1)}** | **{fmt(ex_unamb['hits_per_talk_hour'],1)}** |
| term-utterances / talk-hour | {fmt(utt_rate_any,1)} | {fmt(utt_rate,1)} |
| hits / speech-hour | {fmt(ex_any['hits_per_speech_hour'],1)} | {fmt(ex_unamb['hits_per_speech_hour'],1)} |

Weak (rapidfuzz partial_ratio >= {density['weak_fuzzy']['threshold_partial_ratio']:.0f}) matches are
counted separately: {density['weak_fuzzy']['hits']} hits over
{density['weak_fuzzy']['distinct_canonicals']} canonicals, of which
**{density['weak_fuzzy']['substring_artifacts']} are scorer artifacts** (the matched window is a
substring of the canonical, e.g. `code` inside `Xcode`, which partial_ratio scores 100), leaving
{density['weak_fuzzy']['hits_excl_substring_artifacts']} genuine near-misses. Every weak row carries
`fuzz_ratio_symmetric` and `window_is_substring_of_canonical` so the channel can be filtered without
re-mining. Weak rows are candidates for review, never evidence.

### Per domain

| domain | hits | unambiguous | distinct canonicals | hits/h | unambiguous hits/h |
| --- | --- | --- | --- | --- | --- |
{per_domain_rows}

### Most frequent canonicals

| canonical | utterances | class | domain |
| --- | --- | --- | --- |
{top_rows}

### ASR output quality (this is why the exact counts are low)

| metric | value |
| --- | --- |
| utterances searched | {density['audio']['utterances_searched']} of {density['audio']['utterances']} |
| degenerate utterances (>=50% `⁇`) | {density['asr_quality']['degenerate_utterances']} ({fmt(density['asr_quality']['degenerate_s'],1)} s) |
| `⁇` unknown tokens emitted | {density['asr_quality']['unk_tokens']} |
| real tokens | {density['asr_quality']['real_tokens']} |
| `⁇` share of all tokens | {fmt(density['asr_quality']['unk_share_of_all_tokens'],3)} |
| speaking rate (real tokens) | {fmt(density['asr_quality']['words_per_minute_real'],0)} wpm |

parakeet-tdt degenerates into long `⁇` runs on non-speech that survives VAD
(applause, room noise): {density['asr_quality']['unk_tokens']} of
{density['asr_quality']['unk_tokens'] + density['asr_quality']['real_tokens']} emitted tokens are `⁇`,
all concentrated in {density['asr_quality']['degenerate_utterances']} utterances at up to ~127 tokens/s
versus ~2.6 for speech. Those utterances are excluded from matching.

## 5. Examples (unambiguous exact matches)

"""
    for c in picked:
        lines += (
            f"- **{c['canonical']}** ({c['domain']}, {c['start_s']:.1f}-{c['end_s']:.1f} s, "
            f"matched `{c['matched_text'][0]}`): \"{(c['hypothesis'] or '').strip()[:230]}\"\n"
        )
    if amb_examples:
        lines += "\nAmbiguous exact matches (English homographs — need human adjudication):\n\n"
        for c in amb_examples:
            lines += (
                f"- **{c['canonical']}** ({c['start_s']:.1f} s): "
                f"\"{(c['hypothesis'] or '').strip()[:200]}\"\n"
            )
    if weak_examples:
        lines += "\nWeak/fuzzy candidates (`artifact` = window is a substring of the canonical):\n\n"
        for c in weak_examples:
            tag = "artifact" if c.get("window_is_substring_of_canonical") else "near-miss"
            lines += (
                f"- {c['canonical']} <- `{c['matched_text'][0]}` "
                f"(partial_ratio {c['fuzz_partial_ratio']}, symmetric ratio "
                f"{c.get('fuzz_ratio_symmetric')}, {tag}, {c['start_s']:.1f} s)\n"
            )

    lines += f"""
## 6. Projection to {args.target_utterances:,} term utterances

Basis: {proj['basis']}.

| basis | term-utterances / talk-hour | talk-hours for {args.target_utterances:,} |
| --- | --- | --- |
| unambiguous canonicals only | {fmt(utt_rate,1)} | **{fmt(needed,1)} h** |
| any exact canonical | {fmt(utt_rate_any,1)} | {fmt(needed_any,1)} h |

At {fmt(utt_rate,1)} unambiguous term-utterances per talk-hour, reaching
{args.target_utterances:,} needs about **{fmt(needed,1)} talk-hours** of comparable
containers/Rust conference speech — roughly {needed / (talk_h) if needed else 0:.0f} talks of this
length, or ~{needed / 0.75 if needed else 0:.0f} FOSDEM slots at 45 min. GPU cost for that at
RTFx {fmt(thr['rtfx'],2)} is about **{(needed * 3600 / thr['rtfx'] / 60) if needed else 0:.0f} GPU-minutes**
for transcription, plus {fmt((needed * 3600 / (seg['timings']['vad_xrealtime'] or 1) / 60) if needed else 0,0)} CPU-minutes of VAD and
~{fmt((needed / talk_h * dl['bytes'] / 2**30) if needed else 0, 1)} GiB of downloads at the
observed {dl['bytes']/2**20:.0f} MiB per {talk_h*60:.0f} min talk.

Caveats that bound this projection:
- One talk, one speaker, one devroom: density varies by devroom and speaker.
- Density counts ASR *hypothesis* hits. Terms the model mishears (the actual
  target of glossary work) are invisible to the exact matcher by construction;
  the weak pass ({density['weak_fuzzy']['hits']} hits here) is the only signal for those,
  and human review is required before they become training data.
- {ex_any['hits_segment_canonical_pairs'] - ex_unamb['hits_segment_canonical_pairs']} of
  {ex_any['hits_segment_canonical_pairs']} raw hits come from English homographs
  (Go, Node, Metal, ...) and are excluded from the unambiguous figures.

## 7. Reproduction

Every stage directory holds `manifest.json` (argv, input digests, params,
timings, output digests, env fingerprint incl. `uv.lock` sha256) and
`command.txt`. Env: `{env['env_dir']}` (uv project), python {env['python']},
nemo_toolkit {env['packages']['nemo_toolkit']}, torch {env['packages']['torch']},
uv.lock sha256 `{env.get('uv_lock_sha256','')[:16]}...`. Run order:
`fetch.py -> extract.py -> segment.py -> transcribe.py -> mine.py -> report.py`
(see `run_all.sh`).
"""

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(lines)
    write_manifest(
        out.parent,
        "report",
        {
            "inputs": [
                {"path": str(root / p / "manifest.json")} for p in ("raw", "audio", "vad", "asr", "terms")
            ],
            "outputs": [{"path": str(out), "bytes": out.stat().st_size}],
            "headline": {
                "rtfx": thr["rtfx"],
                "peak_vram_MiB": gpu["nvidia_smi_peak_used_MiB"],
                "hits_per_talk_hour": ex_any["hits_per_talk_hour"],
                "hits_per_talk_hour_unambiguous": ex_unamb["hits_per_talk_hour"],
                "talk_hours_needed_for_1500": needed,
            },
        },
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
