"""Stage 5 — term mining over the hypotheses.

Two match kinds, kept strictly separate in the output:

  exact  case-insensitive whole-token match of a canonical (or an alias, see
         below). The pattern is built from the canonical's alphanumeric runs
         joined by a flexible separator class, wrapped in non-alphanumeric
         lookarounds, so "AES-GCM" matches "aes gcm" / "aes-gcm" / "aesgcm"
         and "X.509" matches "x 509" / "x509", while "kubectl" never matches
         inside "kubectlfoo". Canonicals containing '+' or '#' (C++, C#) are
         matched literally only, because their alnum run is a bare "c".

  weak   rapidfuzz partial_ratio >= 90 against token windows of the hypothesis
         (window length = canonical run count, +/-1). Reported separately and
         never counted in the exact density figures.

IMPORTANT — `heard_as` / alias fields: the frozen `jargon.terms.json` in
data/screen48 does NOT contain them. Its 456 entries carry only
{canonical, domain} (346 rows) or {domain} (110 negative rows), verified by
field-set census. So there is nothing to read for aliases; this stage instead
(a) derives separator/case surface variants from each canonical as described
above and (b) accepts an optional external alias table via --aliases
(JSON: {"canonical": ["heard as form", ...]}) for when such a table exists.
Every alias actually used is recorded in the manifest.

Ambiguity: 173 canonicals include ordinary English homographs (Go, Node,
Metal, React, Rust, Swift, Cargo, Helm, ...). Exact matching is performed as
specified, but each candidate is flagged `ambiguous` and density.json reports
both raw and unambiguous figures, since raw counts for these terms are not
usable evidence of technical-term speech.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from common import Timer, read_jsonl, sha256_file, unk_stats, write_jsonl, write_manifest

SEP = r"[\s\-_/.,'’]*"
ALNUM_RUN = re.compile(r"[A-Za-z0-9]+")
TOKEN = re.compile(r"[a-z0-9]+(?:\+\+|#)?")

# Ordinary English homographs among the canonical set: an exact lowercase token
# match is not by itself evidence that the speaker used the technical term.
AMBIGUOUS_HOMOGRAPHS = {
    "go",
    "node",
    "metal",
    "react",
    "rust",
    "swift",
    "cargo",
    "helm",
    "envoy",
    "consul",
    "instruments",
    "airflow",
    "thrift",
    "snowflake",
    "crystal",
    "dart",
    "bun",
    "elm",
    "nim",
    "vue",
    "uv",
    "julia",
    "rebase",
    "control plane",
}


def build_pattern(surface: str) -> re.Pattern:
    runs = ALNUM_RUN.findall(surface)
    has_symbolic = bool(re.search(r"[+#]", surface))
    if has_symbolic or not runs:
        body = re.escape(surface.lower()).replace(r"\ ", SEP)
    else:
        body = SEP.join(re.escape(r.lower()) for r in runs)
    return re.compile(rf"(?<![A-Za-z0-9]){body}(?![A-Za-z0-9+#])", re.IGNORECASE)


def load_terms(path: str | Path) -> tuple[dict[str, str], dict[str, int], dict[str, int]]:
    data = json.loads(Path(path).read_text())
    domain_of: dict[str, str] = {}
    rows_per_canonical: Counter[str] = Counter()
    fieldsets: Counter[str] = Counter()
    for entry in data.values():
        fieldsets["+".join(sorted(entry.keys()))] += 1
        canonical = entry.get("canonical")
        if not canonical:
            continue
        domain_of[canonical] = entry["domain"]
        rows_per_canonical[canonical] += 1
    return domain_of, rows_per_canonical, fieldsets


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--hypotheses", required=True)
    ap.add_argument("--terms", required=True, help="jargon.terms.json")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--aliases", default=None, help="optional {canonical: [heard_as, ...]} JSON")
    ap.add_argument("--weak-threshold", type=float, default=90.0)
    ap.add_argument("--weak-min-chars", type=int, default=5, help="skip weak matching for shorter canonicals")
    ap.add_argument("--talk-duration-s", type=float, default=None, help="wall-clock talk duration for per-hour rates")
    ap.add_argument("--speaker-note", default=None)
    args = ap.parse_args()

    from rapidfuzz import fuzz, process

    timer = Timer()
    hyps = read_jsonl(args.hypotheses)
    domain_of, rows_per_canonical, fieldsets = load_terms(args.terms)
    canonicals = sorted(domain_of)

    aliases: dict[str, list[str]] = {}
    if args.aliases:
        aliases = {k: list(v) for k, v in json.loads(Path(args.aliases).read_text()).items()}

    patterns: dict[str, list[tuple[str, re.Pattern]]] = {}
    for canonical in canonicals:
        surfaces = [canonical, *aliases.get(canonical, [])]
        patterns[canonical] = [(s, build_pattern(s)) for s in surfaces]

    run_counts = {c: max(1, len(ALNUM_RUN.findall(c))) for c in canonicals}
    weak_pool = [c for c in canonicals if len(c.replace(" ", "")) >= args.weak_min_chars]

    candidates: list[dict] = []
    speech_s = 0.0
    seg_hits: dict[str, set[str]] = defaultdict(set)
    per_domain_hits: Counter[str] = Counter()
    per_domain_hits_unamb: Counter[str] = Counter()
    per_canonical_hits: Counter[str] = Counter()
    weak_count = 0
    weak_substring_artifacts = 0
    occurrences_total = 0
    degenerate_rows = 0
    degenerate_s = 0.0
    unk_tokens_total = 0
    real_tokens_total = 0

    for row in hyps:
        text = row.get("text") or ""
        speech_s += float(row.get("duration_s") or 0.0)
        unk = unk_stats(text)
        unk_tokens_total += unk["unk_tokens"]
        real_tokens_total += unk["tokens"] - unk["unk_tokens"]
        if unk["degenerate"]:
            # parakeet ⁇-loop on non-speech: no term can be recovered from it,
            # and feeding it to the fuzzy matcher only manufactures noise.
            degenerate_rows += 1
            degenerate_s += float(row.get("duration_s") or 0.0)
            continue
        lowered = text.lower()
        matched_here: set[str] = set()

        for canonical in canonicals:
            spans: list[tuple[int, int]] = []
            used_surface = None
            for surface, pat in patterns[canonical]:
                found = [(m.start(), m.end()) for m in pat.finditer(lowered)]
                if found:
                    spans.extend(found)
                    used_surface = used_surface or surface
            if not spans:
                continue
            spans = sorted(set(spans))
            domain = domain_of[canonical]
            ambiguous = canonical.lower() in AMBIGUOUS_HOMOGRAPHS or len(canonical.replace(" ", "")) <= 2
            matched_here.add(canonical)
            per_domain_hits[domain] += 1
            per_canonical_hits[canonical] += 1
            if not ambiguous:
                per_domain_hits_unamb[domain] += 1
                seg_hits[row["segment_id"]].add(canonical)
            occurrences_total += len(spans)
            candidates.append(
                {
                    "segment_id": row["segment_id"],
                    "talk_id": row["talk_id"],
                    "start_s": row["start_s"],
                    "end_s": row["end_s"],
                    "duration_s": row["duration_s"],
                    "wav_path": row["wav_path"],
                    "canonical": canonical,
                    "domain": domain,
                    "match_kind": "exact",
                    "matched_surface": used_surface,
                    "occurrences": len(spans),
                    "spans": [list(s) for s in spans],
                    "matched_text": [text[s:e] for s, e in spans],
                    "ambiguous": ambiguous,
                    "hypothesis": text,
                    "asr_score": row.get("score"),
                    "asr_n_words": row.get("n_words"),
                }
            )

        # ---- weak (fuzzy) pass over token windows -------------------------
        toks = [(m.group(0), m.start(), m.end()) for m in TOKEN.finditer(lowered)]
        if not toks:
            continue
        windows: list[str] = []
        win_meta: list[tuple[int, int]] = []
        for n in (1, 2, 3):
            for i in range(0, max(0, len(toks) - n + 1)):
                chunk = toks[i : i + n]
                windows.append(" ".join(t[0] for t in chunk))
                win_meta.append((chunk[0][1], chunk[-1][2]))
        queries = [c for c in weak_pool if c not in matched_here and run_counts[c] <= 3]
        if not queries or not windows:
            continue
        scores = process.cdist(
            [q.lower() for q in queries],
            windows,
            scorer=fuzz.partial_ratio,
            score_cutoff=args.weak_threshold,
            workers=-1,
        )
        win_lens = [len(w) for w in windows]
        for qi, canonical in enumerate(queries):
            # partial_ratio scores the best-matching *substring*, so a window
            # shorter than the canonical scores 100 whenever it is contained in
            # it: partial_ratio("prometheus", "the") == 100. Without this length
            # floor the weak pass produced 4510 hits on 147 utterances, all of
            # that shape. Require the window to be >= 80% of the canonical.
            min_win_chars = int(0.8 * len(canonical))
            best_j, best = -1, 0.0
            for j, sc in enumerate(scores[qi]):
                if sc >= args.weak_threshold and sc > best and win_lens[j] >= min_win_chars:
                    # window token count must be within +/-1 of the canonical's
                    n_win = windows[j].count(" ") + 1
                    if abs(n_win - run_counts[canonical]) <= 1:
                        best, best_j = float(sc), j
            if best_j < 0:
                continue
            weak_count += 1
            s, e = win_meta[best_j]
            win_norm = windows[best_j]
            can_norm = canonical.lower()
            # partial_ratio == 100 whenever the window is a substring of the
            # canonical ("code" in "xcode"), which is an artifact of the scorer,
            # not a mishearing. Label it and carry the symmetric ratio so the
            # channel can be filtered downstream without re-running the stage.
            is_substring = win_norm.replace(" ", "") in can_norm.replace(" ", "")
            sym_ratio = round(float(fuzz.ratio(can_norm, win_norm)), 1)
            if is_substring:
                weak_substring_artifacts += 1
            candidates.append(
                {
                    "segment_id": row["segment_id"],
                    "talk_id": row["talk_id"],
                    "start_s": row["start_s"],
                    "end_s": row["end_s"],
                    "duration_s": row["duration_s"],
                    "wav_path": row["wav_path"],
                    "canonical": canonical,
                    "domain": domain_of[canonical],
                    "match_kind": "weak_fuzzy",
                    "matched_surface": None,
                    "fuzz_partial_ratio": round(best, 1),
                    "fuzz_ratio_symmetric": sym_ratio,
                    "window_is_substring_of_canonical": is_substring,
                    "matched_text": [text[s:e]],
                    "spans": [[s, e]],
                    "occurrences": 1,
                    "ambiguous": canonical.lower() in AMBIGUOUS_HOMOGRAPHS,
                    "hypothesis": text,
                    "asr_score": row.get("score"),
                    "asr_n_words": row.get("n_words"),
                }
            )

    mine_s = timer.lap()
    out_dir = Path(args.out_dir)
    cand_digest = write_jsonl(out_dir / "candidates.jsonl", candidates)

    talks = sorted({r["talk_id"] for r in hyps})
    speech_h = speech_s / 3600.0
    talk_s = args.talk_duration_s
    talk_h = (talk_s / 3600.0) if talk_s else None

    exact = [c for c in candidates if c["match_kind"] == "exact"]
    exact_unamb = [c for c in exact if not c["ambiguous"]]
    utt_with_unamb = len({c["segment_id"] for c in exact_unamb})
    utt_with_any = len({c["segment_id"] for c in exact})

    def per_hour(n: int, hours: float | None) -> float | None:
        return round(n / hours, 1) if hours and hours > 0 else None

    domains = sorted({domain_of[c] for c in canonicals})
    density = {
        "talks": talks,
        "n_talks": len(talks),
        "speaker_attribution": args.speaker_note or "single presenter per talk; FOSDEM does not publish per-utterance speaker labels",
        "n_distinct_speakers_assumed": len(talks),
        "audio": {
            "speech_s": round(speech_s, 1),
            "speech_h": round(speech_h, 4),
            "talk_wallclock_s": talk_s,
            "talk_wallclock_h": round(talk_h, 4) if talk_h else None,
            "utterances": len(hyps),
            "utterances_searched": len(hyps) - degenerate_rows,
        },
        "asr_quality": {
            "degenerate_utterances": degenerate_rows,
            "degenerate_s": round(degenerate_s, 1),
            "unk_tokens": unk_tokens_total,
            "real_tokens": real_tokens_total,
            "unk_share_of_all_tokens": round(
                unk_tokens_total / (unk_tokens_total + real_tokens_total), 4
            )
            if (unk_tokens_total + real_tokens_total)
            else 0.0,
            "words_per_minute_real": round(real_tokens_total / (speech_s / 60.0), 1) if speech_s else None,
            "note": "degenerate = >=50% U+2047 (⁇) tokens; excluded from matching, kept in audio totals",
        },
        "terms": {
            "canonicals_in_taxonomy": len(canonicals),
            "taxonomy_fieldsets": dict(fieldsets),
            "has_heard_as_field": False,
            "aliases_supplied": {k: v for k, v in aliases.items()},
        },
        "exact": {
            "hits_segment_canonical_pairs": len(exact),
            "occurrences": occurrences_total,
            "distinct_canonicals": len({c["canonical"] for c in exact}),
            "utterances_with_hit": utt_with_any,
            "hits_per_speech_hour": per_hour(len(exact), speech_h),
            "hits_per_talk_hour": per_hour(len(exact), talk_h),
            "utterances_with_hit_per_talk_hour": per_hour(utt_with_any, talk_h),
        },
        "exact_unambiguous": {
            "hits_segment_canonical_pairs": len(exact_unamb),
            "distinct_canonicals": len({c["canonical"] for c in exact_unamb}),
            "utterances_with_hit": utt_with_unamb,
            "hits_per_speech_hour": per_hour(len(exact_unamb), speech_h),
            "hits_per_talk_hour": per_hour(len(exact_unamb), talk_h),
            "utterances_with_hit_per_talk_hour": per_hour(utt_with_unamb, talk_h),
        },
        "weak_fuzzy": {
            "threshold_partial_ratio": args.weak_threshold,
            "hits": weak_count,
            "substring_artifacts": weak_substring_artifacts,
            "hits_excl_substring_artifacts": weak_count - weak_substring_artifacts,
            "distinct_canonicals": len({c["canonical"] for c in candidates if c["match_kind"] == "weak_fuzzy"}),
            "note": (
                "partial_ratio returns 100 when the window is a substring of the canonical "
                "('code' in 'Xcode'); those rows are labelled window_is_substring_of_canonical "
                "and carry fuzz_ratio_symmetric so they can be filtered without re-mining."
            ),
            "hits_per_talk_hour": per_hour(weak_count, talk_h),
        },
        "per_domain": {
            d: {
                "hits": per_domain_hits.get(d, 0),
                "hits_unambiguous": per_domain_hits_unamb.get(d, 0),
                "distinct_canonicals": len({c["canonical"] for c in exact if c["domain"] == d}),
                "hits_per_talk_hour": per_hour(per_domain_hits.get(d, 0), talk_h),
                "hits_unambiguous_per_talk_hour": per_hour(per_domain_hits_unamb.get(d, 0), talk_h),
            }
            for d in domains
        },
        "top_canonicals": [
            [
                name,
                n,
                "ambiguous" if (name.lower() in AMBIGUOUS_HOMOGRAPHS or len(name.replace(" ", "")) <= 2) else "unambiguous",
                domain_of[name],
            ]
            for name, n in per_canonical_hits.most_common(25)
        ],
        "projection_to_1500_term_utterances": {
            "basis": "distinct utterances containing >=1 unambiguous exact canonical",
            "utterances_with_hit": utt_with_unamb,
            "talk_hours_processed": round(talk_h, 4) if talk_h else None,
            "talk_hours_needed": (
                round(1500.0 / per_hour(utt_with_unamb, talk_h), 1)
                if per_hour(utt_with_unamb, talk_h)
                else None
            ),
            "basis_any": "distinct utterances containing >=1 exact canonical incl. ambiguous homographs",
            "talk_hours_needed_any": (
                round(1500.0 / per_hour(utt_with_any, talk_h), 1) if per_hour(utt_with_any, talk_h) else None
            ),
        },
    }
    (out_dir / "density.json").write_text(json.dumps(density, indent=2) + "\n")

    payload = {
        "inputs": [
            {"path": args.hypotheses, "sha256": sha256_file(args.hypotheses), "utterances": len(hyps)},
            {"path": args.terms, "sha256": sha256_file(args.terms), "canonicals": len(canonicals)},
        ],
        "params": {
            "weak_threshold": args.weak_threshold,
            "weak_min_chars": args.weak_min_chars,
            "separator_class": SEP,
            "ambiguous_homographs": sorted(AMBIGUOUS_HOMOGRAPHS),
            "aliases_file": args.aliases,
            "heard_as_available_in_terms_file": False,
        },
        "results": {
            "candidates": len(candidates),
            "exact": len(exact),
            "exact_unambiguous": len(exact_unamb),
            "weak_fuzzy": weak_count,
            "distinct_canonicals_exact": density["exact"]["distinct_canonicals"],
        },
        "timings": {"mine_s": mine_s, "stage_total_s": timer.lap()},
        "outputs": [cand_digest, {"path": str(out_dir / "density.json"), "sha256": sha256_file(out_dir / "density.json")}],
    }
    write_manifest(out_dir, "mine", payload)
    print(json.dumps({k: density[k] for k in ("exact", "exact_unambiguous", "weak_fuzzy")}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
