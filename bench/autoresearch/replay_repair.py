"""Replay deterministic contextual repair over the frozen jargon baseline.

This is a CPU-only research instrument. It never decodes audio: it replays the
baseline ``final_text`` values through increasingly permissive vocabulary-only
repair policies, then scores every output with the same accuracy semantics as
``autoresearch/score.py``.

Run from ``bench/`` so the pinned benchmark environment supplies RapidFuzz and
the ``voiceour_bench`` package::

    uv --no-config run --offline python autoresearch/replay_repair.py

The fixed sweep writes an auditable frontier, every repaired transcript, and a
row-level taxonomy of the baseline misses below
``.build/asr-research/three-bets/repair/``.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sys
import unicodedata
from dataclasses import dataclass
from importlib.metadata import version
from itertools import product
from pathlib import Path
from typing import Iterable

from rapidfuzz.distance import Levenshtein
from voiceour_bench.metrics import fwer, uwer

REPO = Path(__file__).resolve().parents[2]
DEFAULT_RESULTS = REPO / ".build/asr-research/three-bets/baseline-run41.results.jsonl"
DEFAULT_GENERAL_CORPUS = REPO / "bench/autoresearch/corpus.manifest.jsonl"
DEFAULT_JARGON_CORPUS = REPO / "benchmarks/data/jargon/manifest.jsonl"
DEFAULT_JARGON_TERMS = REPO / "bench/autoresearch/jargon.terms.json"
DEFAULT_OUTPUT_DIR = REPO / ".build/asr-research/three-bets/repair"
DEFAULT_DICTIONARY = Path("/usr/share/dict/words")

THRESHOLDS = (0.60, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95)
MIN_PHONETIC_THRESHOLD = min(THRESHOLDS)
MAX_WINDOW_WORDS = 5
SAFE_FWER_DELTA = 0.002
TERM_CONDITIONAL_FWER_DELTA = 0.001
MISS_CATEGORIES = (
    "case_only",
    "lexical_variant",
    "phonetic_near",
    "phonetic_far_or_absent",
)
EPSILON = 1e-12

_BOUNDARY_PREFIX = r"(?<![A-Za-z0-9_])"
_BOUNDARY_SUFFIX = r"(?![A-Za-z0-9_])"
_TOKEN_PATTERN = re.compile(r"[A-Za-z0-9+#/_-]+(?:\.[A-Za-z0-9+#/_-]+)*")
_CANONICAL_BOUNDARIES = (
    (re.compile(r"([A-Z]+)([A-Z][a-z])"), r"\1 \2"),
    (re.compile(r"([a-z])([A-Z])"), r"\1 \2"),
    (re.compile(r"([A-Za-z])([0-9])"), r"\1 \2"),
    (re.compile(r"([0-9])([A-Za-z])"), r"\1 \2"),
)
_DIGIT_WORDS = {
    "0": "zero",
    "1": "one",
    "2": "two",
    "3": "three",
    "4": "four",
    "5": "five",
    "6": "six",
    "7": "seven",
    "8": "eight",
    "9": "nine",
}
_SYMBOL_WORDS = {
    "#": " sharp ",
    "+": " plus ",
    "/": " slash ",
    "&": " and ",
    "@": " at ",
    "%": " percent ",
}
_SEPARATOR_WORDS = {
    ".": " dot ",
    "-": " dash ",
    "_": " underscore ",
}


@dataclass(frozen=True)
class Candidate:
    start: int
    end: int
    canonical: str
    kind: str
    score: float
    discovery_order: int
    matched: str


@dataclass(frozen=True)
class RepairEvent:
    start: int
    end: int
    before: str
    after: str
    kind: str
    score: float

    def as_dict(self) -> dict[str, object]:
        return {
            "after": self.after,
            "before": self.before,
            "end": self.end,
            "kind": self.kind,
            "score": round(self.score, 9),
            "start": self.start,
        }


@dataclass(frozen=True)
class RepairResult:
    text: str
    events: tuple[RepairEvent, ...]


@dataclass(frozen=True)
class ReplayInputs:
    general_ids: tuple[str, ...]
    jargon_ids: tuple[str, ...]
    general_refs: dict[str, str]
    jargon_refs: dict[str, str]
    general_finals: dict[str, str]
    jargon_finals: dict[str, str]
    annotations: dict[str, dict[str, str]]


@dataclass(frozen=True)
class ReplayVariant:
    strategy: str
    threshold: float | None
    outputs: dict[str, str]
    repairs: dict[str, tuple[RepairEvent, ...]]


def canonical_tokens(canonical: str) -> tuple[str, ...]:
    """Mirror ``Glossary.derivedAliases`` token boundaries."""

    tokenized = re.sub(r"[\s._-]+", " ", canonical)
    for pattern, replacement in _CANONICAL_BOUNDARIES:
        tokenized = pattern.sub(replacement, tokenized)
    return tuple(tokenized.split())


def _digit_spoken(value: str) -> str:
    return "".join(f" {_DIGIT_WORDS[char]} " if char.isdigit() else char for char in value)


def _symbol_variant(canonical: str, *, name_separators: bool) -> str:
    pieces: list[str] = []
    for char in canonical:
        if char in _SYMBOL_WORDS:
            pieces.append(_SYMBOL_WORDS[char])
        elif char in _SEPARATOR_WORDS:
            pieces.append(_SEPARATOR_WORDS[char] if name_separators else " ")
        else:
            pieces.append(char)
    return "".join(pieces)


def derived_aliases(canonical: str) -> tuple[str, ...]:
    """Return only aliases mechanically derivable from *canonical*.

    The first two forms exactly mirror the Swift product rule: lowercase words
    split at separators/case/digit boundaries, then the same form with acronym
    tokens letter-spaced. The research replay additionally enumerates separator
    joins, one split in an otherwise opaque alphabetic token (``kube ctl``),
    standard numeronyms (``k8s``), and literal spoken symbol/digit forms. No
    term-specific alias list participates.
    """

    tokens = canonical_tokens(canonical)
    candidates: list[str] = []
    if len(tokens) >= 2:
        candidates.append(" ".join(tokens).lower())
        candidates.append(
            " ".join(
                " ".join(token).lower()
                if len(token) >= 2 and token.isupper()
                else token.lower()
                for token in tokens
            )
        )
        for joins in product((" ", ""), repeat=len(tokens) - 1):
            candidates.append(
                "".join(
                    token + (joins[index] if index < len(joins) else "")
                    for index, token in enumerate(tokens)
                ).lower()
            )

    compact = "".join(char for char in canonical if char.isalnum())
    if len(tokens) == 1 and compact.isalpha() and len(compact) >= 4:
        for split in range(2, len(compact) - 1):
            candidates.append(f"{compact[:split]} {compact[split:]}".lower())
        candidates.append(f"{compact[0]}{len(compact) - 2}{compact[-1]}".lower())

    separator_form = _symbol_variant(canonical, name_separators=False)
    spoken_form = _symbol_variant(canonical, name_separators=True)
    candidates.extend(
        (
            separator_form.lower(),
            spoken_form.lower(),
            _digit_spoken(separator_form).lower(),
            _digit_spoken(spoken_form).lower(),
        )
    )

    canonical_key = " ".join(canonical.split()).casefold()
    aliases: list[str] = []
    seen = {canonical_key}
    for candidate in candidates:
        alias = " ".join(candidate.split())
        key = alias.casefold()
        if alias and key not in seen:
            seen.add(key)
            aliases.append(alias)
    return tuple(aliases)


def surface_pattern(surface: str, flags: int = 0) -> re.Pattern[str]:
    """Compile the scorer's exact ``[A-Za-z0-9_]`` boundary semantics."""

    return re.compile(_BOUNDARY_PREFIX + re.escape(surface) + _BOUNDARY_SUFFIX, flags)

def partition_surfaces(
    surfaces: Iterable[str],
    negative_references: Iterable[str],
    dictionary_words: set[str],
) -> tuple[dict[str, tuple[str, ...]], tuple[str, ...]]:
    """Partition surfaces by deterministic ordinary-language collision risk."""

    references = tuple(negative_references)
    risky: dict[str, tuple[str, ...]] = {}
    unambiguous: list[str] = []
    for surface in sorted(set(surfaces)):
        lowered = surface.lower()
        reasons: list[str] = []
        if lowered in dictionary_words:
            reasons.append("dictionary_word")
        if len(lowered) <= 2:
            reasons.append("length_le_2")
        pattern = surface_pattern(surface, re.IGNORECASE)
        if any(pattern.search(reference) for reference in references):
            reasons.append("negative_reference")
        if reasons:
            risky[surface] = tuple(reasons)
        else:
            unambiguous.append(surface)
    return risky, tuple(unambiguous)


def alias_pattern(alias: str) -> re.Pattern[str]:
    parts = [re.escape(part) for part in alias.split()]
    if not parts:
        raise ValueError("an alias cannot be empty")
    return re.compile(
        _BOUNDARY_PREFIX + r"\s+".join(parts) + _BOUNDARY_SUFFIX,
        re.IGNORECASE,
    )


def grapheme_key(value: str) -> str:
    ascii_value = (
        unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii").lower()
    )
    expanded = "".join(_SYMBOL_WORDS.get(char, char) for char in ascii_value)
    return "".join(char for char in expanded if char.isalnum())


def phonetic_key(value: str) -> str:
    """Return a compact deterministic English G2P-lite key."""

    key = grapheme_key(value)
    replacements = (
        ("tch", "C"),
        ("sch", "sk"),
        ("tion", "Sn"),
        ("sion", "Sn"),
        ("ough", "A"),
        ("ph", "f"),
        ("ght", "t"),
        ("ch", "C"),
        ("sh", "S"),
        ("th", "T"),
        ("qu", "kw"),
        ("ck", "k"),
        ("ng", "N"),
        ("wh", "w"),
        ("wr", "r"),
        ("kn", "n"),
    )
    for source, replacement in replacements:
        key = key.replace(source, replacement)
    key = re.sub(r"c(?=[eiy])", "s", key)
    key = re.sub(r"g(?=[eiy])", "j", key)
    key = key.replace("x", "ks").replace("q", "k").replace("c", "k").replace("z", "s")
    key = re.sub(r"[aeiouy]+", "A", key)
    return re.sub(r"(.)\1+", r"\1", key)


def _similarity_from_keys(
    left_grapheme: str,
    left_phone: str,
    right_grapheme: str,
    right_phone: str,
) -> float:
    if not left_grapheme or not right_grapheme:
        return 0.0
    grapheme_score = float(Levenshtein.normalized_similarity(left_grapheme, right_grapheme))
    phone_score = float(Levenshtein.normalized_similarity(left_phone, right_phone))
    blended = 0.35 * grapheme_score + 0.65 * phone_score
    return max(grapheme_score, blended)


def phonetic_similarity(left: str, right: str) -> float:
    """Score a span against a vocabulary surface in ``[0, 1]``."""

    return _similarity_from_keys(
        grapheme_key(left),
        phonetic_key(left),
        grapheme_key(right),
        phonetic_key(right),
    )


def _overlaps(candidate: Candidate, accepted: Iterable[Candidate]) -> bool:
    return any(candidate.start < other.end and other.start < candidate.end for other in accepted)


def _resolve_longest(candidates: Iterable[Candidate]) -> list[Candidate]:
    ordered = sorted(
        candidates,
        key=lambda candidate: (
            -(candidate.end - candidate.start),
            candidate.start,
            candidate.discovery_order,
        ),
    )
    accepted: list[Candidate] = []
    for candidate in ordered:
        if not _overlaps(candidate, accepted):
            accepted.append(candidate)
    return accepted


def _apply_candidates(text: str, accepted: Iterable[Candidate]) -> RepairResult:
    accepted_list = list(accepted)
    output = text
    for candidate in sorted(accepted_list, key=lambda item: item.start, reverse=True):
        output = output[: candidate.start] + candidate.canonical + output[candidate.end :]

    events = tuple(
        RepairEvent(
            start=candidate.start,
            end=candidate.end,
            before=candidate.matched,
            after=candidate.canonical,
            kind=candidate.kind,
            score=candidate.score,
        )
        for candidate in sorted(accepted_list, key=lambda item: item.start)
        if candidate.matched != candidate.canonical
    )
    return RepairResult(text=output, events=events)


class Vocabulary:
    """Fixed, collision-filtered vocabulary used by every replay strategy."""

    def __init__(
        self,
        surfaces: Iterable[str],
        *,
        protected_surfaces: Iterable[str] = (),
    ):
        ordered = tuple(sorted(set(surfaces)))
        if not ordered:
            raise ValueError("vocabulary must not be empty")
        canonical_owners: dict[str, set[str]] = {}
        raw_aliases: dict[str, tuple[str, ...]] = {}
        for canonical in ordered:
            key = " ".join(canonical.split()).casefold()
            canonical_owners.setdefault(key, set()).add(canonical)
            raw_aliases[canonical] = derived_aliases(canonical)
        if any(len(owners) != 1 for owners in canonical_owners.values()):
            raise ValueError("canonical surfaces collide case-insensitively")

        alias_owners = {key: set(owners) for key, owners in canonical_owners.items()}
        for canonical in ordered:
            for alias in raw_aliases[canonical]:
                alias_owners.setdefault(alias.casefold(), set()).add(canonical)

        self.surfaces = ordered
        protected = tuple(sorted(set(protected_surfaces)))
        if set(ordered) & set(protected):
            raise ValueError("active and protected surfaces must be disjoint")
        self.protected_surfaces = protected
        self._canonical_rank = {canonical: rank for rank, canonical in enumerate(ordered)}
        self.aliases = {
            canonical: tuple(
                sorted(
                    (
                        alias
                        for alias in raw_aliases[canonical]
                        if alias_owners[alias.casefold()] == {canonical}
                    ),
                    key=lambda alias: (-len(alias), alias.casefold(), alias),
                )
            )
            for canonical in ordered
        }
        self._profiles = {
            canonical: self._profile_keys(canonical) for canonical in self.surfaces
        }
        self._phonetic_cache: dict[str, tuple[list[Candidate], tuple[Candidate, ...]]] = {}

    def _profile_keys(self, canonical: str) -> tuple[tuple[str, str], ...]:
        profiles: list[tuple[str, str]] = []
        seen: set[tuple[str, str]] = set()
        for surface in (canonical, *self.aliases[canonical]):
            pair = (grapheme_key(surface), phonetic_key(surface))
            if pair[0] and pair not in seen:
                seen.add(pair)
                profiles.append(pair)
        return tuple(profiles)

    def profiles_for(self, canonical: str) -> tuple[tuple[str, str], ...]:
        return self._profiles[canonical]

    def _protected_spans(self, text: str) -> tuple[Candidate, ...]:
        spans: list[Candidate] = []
        for discovery_order, surface in enumerate(self.protected_surfaces):
            for match in alias_pattern(surface).finditer(text):
                spans.append(
                    Candidate(
                        start=match.start(),
                        end=match.end(),
                        canonical=surface,
                        kind="protected",
                        score=1.0,
                        discovery_order=discovery_order,
                        matched=match.group(0),
                    )
                )
        return tuple(spans)

    def lexical_matches(self, text: str, *, include_aliases: bool) -> list[Candidate]:
        candidates: list[Candidate] = []
        protected = self._protected_spans(text)
        discovery_order = 0
        for canonical in self.surfaces:
            aliases = (canonical, *self.aliases[canonical]) if include_aliases else (canonical,)
            for alias_index, alias in enumerate(aliases):
                pattern = alias_pattern(alias)
                kind = "canonical" if alias_index == 0 else "alias"
                for match in pattern.finditer(text):
                    candidate = Candidate(
                        start=match.start(),
                        end=match.end(),
                        canonical=canonical,
                        kind=kind,
                        score=1.0,
                        discovery_order=discovery_order,
                        matched=match.group(0),
                    )
                    discovery_order += 1
                    if not _overlaps(candidate, protected):
                        candidates.append(candidate)
        return candidates

    def score_span(self, span: str, canonical: str) -> float:
        left_grapheme = grapheme_key(span)
        left_phone = phonetic_key(span)
        return max(
            (
                _similarity_from_keys(
                    left_grapheme,
                    left_phone,
                    right_grapheme,
                    right_phone,
                )
                for right_grapheme, right_phone in self._profiles[canonical]
            ),
            default=0.0,
        )

    def best_span(self, text: str, canonical: str) -> tuple[float, int, int, str]:
        tokens = tuple(_TOKEN_PATTERN.finditer(text))
        best = (0.0, 0, 0, "")
        for width in range(1, min(MAX_WINDOW_WORDS, len(tokens)) + 1):
            for start_index in range(len(tokens) - width + 1):
                start = tokens[start_index].start()
                end = tokens[start_index + width - 1].end()
                span = text[start:end]
                score = self.score_span(span, canonical)
                if score > best[0] + EPSILON:
                    best = (score, start, end, span)
                elif abs(score - best[0]) <= EPSILON:
                    if start < best[1] or (start == best[1] and end - start > best[2] - best[1]):
                        best = (score, start, end, span)
        return best

    def _phonetic_candidates(self, text: str) -> tuple[list[Candidate], tuple[Candidate, ...]]:
        cached = self._phonetic_cache.get(text)
        if cached is not None:
            return cached

        lexical = _resolve_longest(self.lexical_matches(text, include_aliases=True))
        protected = self._protected_spans(text)
        tokens = tuple(_TOKEN_PATTERN.finditer(text))
        candidates: list[Candidate] = []
        discovery_order = max((item.discovery_order for item in lexical), default=-1) + 1
        for width in range(1, min(MAX_WINDOW_WORDS, len(tokens)) + 1):
            for start_index in range(len(tokens) - width + 1):
                start = tokens[start_index].start()
                end = tokens[start_index + width - 1].end()
                probe = Candidate(start, end, "", "phonetic", 0.0, 0, text[start:end])
                if _overlaps(probe, lexical) or _overlaps(probe, protected):
                    continue

                span = text[start:end]
                best_surface = ""
                best_score = 0.0
                for canonical in self.surfaces:
                    score = self.score_span(span, canonical)
                    if score > best_score + EPSILON:
                        best_surface = canonical
                        best_score = score
                    elif abs(score - best_score) <= EPSILON and best_surface:
                        if self._canonical_rank[canonical] < self._canonical_rank[best_surface]:
                            best_surface = canonical
                if best_surface and best_score + EPSILON >= MIN_PHONETIC_THRESHOLD:
                    candidates.append(
                        Candidate(
                            start=start,
                            end=end,
                            canonical=best_surface,
                            kind="phonetic",
                            score=best_score,
                            discovery_order=discovery_order,
                            matched=span,
                        )
                    )
                    discovery_order += 1

        cached = (lexical, tuple(candidates))
        self._phonetic_cache[text] = cached
        return cached

    def repair(
        self,
        text: str,
        *,
        strategy: str,
        threshold: float | None = None,
    ) -> RepairResult:
        strategy_key = strategy.lower()
        if strategy_key == "recase":
            accepted = _resolve_longest(self.lexical_matches(text, include_aliases=False))
            return _apply_candidates(text, accepted)
        if strategy_key == "lexical":
            accepted = _resolve_longest(self.lexical_matches(text, include_aliases=True))
            return _apply_candidates(text, accepted)
        if strategy_key != "phonetic":
            raise ValueError(f"unknown repair strategy {strategy!r}")
        if threshold is None or not 0.0 <= threshold <= 1.0:
            raise ValueError("phonetic repair requires a threshold in [0, 1]")

        lexical, fuzzy = self._phonetic_candidates(text)
        accepted = list(lexical)
        eligible = [candidate for candidate in fuzzy if candidate.score + EPSILON >= threshold]
        eligible.sort(
            key=lambda candidate: (
                -candidate.score,
                -(candidate.end - candidate.start),
                candidate.start,
                self._canonical_rank[candidate.canonical],
                candidate.discovery_order,
            )
        )
        for candidate in eligible:
            if not _overlaps(candidate, accepted):
                accepted.append(candidate)
        return _apply_candidates(text, accepted)


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{line_number}: expected a JSON object")
        rows.append(value)
    return rows


def _ordered_manifest(path: Path) -> tuple[tuple[str, ...], dict[str, str]]:
    ids: list[str] = []
    references: dict[str, str] = {}
    for row in read_jsonl(path):
        row_id = str(row["id"])
        if row_id in references:
            raise ValueError(f"{path}: duplicate id {row_id!r}")
        ids.append(row_id)
        references[row_id] = str(row["reference"])
    return tuple(ids), references


def load_inputs(
    results_path: Path,
    general_corpus_path: Path,
    jargon_corpus_path: Path,
    jargon_terms_path: Path,
) -> ReplayInputs:
    general_ids, general_refs = _ordered_manifest(general_corpus_path)
    jargon_ids, jargon_refs = _ordered_manifest(jargon_corpus_path)
    annotations = json.loads(jargon_terms_path.read_text(encoding="utf-8"))
    if not isinstance(annotations, dict):
        raise ValueError(f"{jargon_terms_path}: expected one object")
    if set(annotations) != set(jargon_ids):
        raise ValueError("jargon annotations do not exactly cover the jargon manifest")

    general_finals: dict[str, str] = {}
    jargon_finals: dict[str, str] = {}
    for row in read_jsonl(results_path):
        if row.get("type") != "row":
            continue
        if row.get("error") is not None:
            raise ValueError(f"baseline row {row.get('id')!r} contains an error")
        raw_id = str(row["id"])
        if raw_id.endswith("#p0"):
            row_id = raw_id.removesuffix("#p0")
            if row_id in general_finals:
                raise ValueError(f"duplicate general baseline row {row_id!r}")
            general_finals[row_id] = str(row["final_text"])
        elif raw_id.endswith("#j0"):
            row_id = raw_id.removesuffix("#j0")
            if row_id in jargon_finals:
                raise ValueError(f"duplicate jargon baseline row {row_id!r}")
            jargon_finals[row_id] = str(row["final_text"])

    if set(general_finals) != set(general_ids):
        raise ValueError("baseline #p0 rows do not exactly cover the general manifest")
    if set(jargon_finals) != set(jargon_ids):
        raise ValueError("baseline #j0 rows do not exactly cover the jargon manifest")

    typed_annotations = {
        str(row_id): {str(key): str(value) for key, value in entry.items()}
        for row_id, entry in annotations.items()
    }
    return ReplayInputs(
        general_ids=general_ids,
        jargon_ids=jargon_ids,
        general_refs=general_refs,
        jargon_refs=jargon_refs,
        general_finals=general_finals,
        jargon_finals=jargon_finals,
        annotations=typed_annotations,
    )


def _variant_sha(ids: Iterable[str], outputs: dict[str, str]) -> str:
    blob = "".join(f"{row_id}\t{outputs[row_id]}\n" for row_id in ids)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def score_variant(inputs: ReplayInputs, variant: ReplayVariant) -> dict[str, object]:
    positive_rows = [
        (row_id, inputs.annotations[row_id]["canonical"])
        for row_id in inputs.jargon_ids
        if "canonical" in inputs.annotations[row_id]
    ]
    negative_ids = [
        row_id for row_id in inputs.jargon_ids if "canonical" not in inputs.annotations[row_id]
    ]
    surfaces = sorted({canonical for _, canonical in positive_rows})
    patterns = {surface: surface_pattern(surface) for surface in surfaces}

    hits = sum(
        1
        for row_id, canonical in positive_rows
        if patterns[canonical].search(variant.outputs[row_id])
    )
    false_terms = 0
    for row_id in negative_ids:
        hypothesis = variant.outputs[row_id]
        reference = inputs.jargon_refs[row_id]
        for surface in surfaces:
            pattern = patterns[surface]
            if pattern.search(hypothesis) and not pattern.search(reference):
                false_terms += 1

    jargon_refs = [inputs.jargon_refs[row_id] for row_id in inputs.jargon_ids]
    jargon_finals = [variant.outputs[row_id] for row_id in inputs.jargon_ids]
    general_refs = [inputs.general_refs[row_id] for row_id in inputs.general_ids]
    general_finals = [inputs.general_finals[row_id] for row_id in inputs.general_ids]
    negative_refs = [inputs.jargon_refs[row_id] for row_id in negative_ids]
    negative_finals = [variant.outputs[row_id] for row_id in negative_ids]

    return {
        "strategy": variant.strategy,
        "threshold": variant.threshold,
        "term_hits": hits,
        "term_opportunities": len(positive_rows),
        "jargon_term_recall": hits / len(positive_rows) if positive_rows else 0.0,
        "jargon_false_terms": false_terms,
        "fwer_negative": fwer(negative_refs, negative_finals),
        "uwer_jargon": uwer(jargon_refs, jargon_finals),
        "uwer_mix": uwer(general_refs + jargon_refs, general_finals + jargon_finals),
        "transcript_sha256": _variant_sha(inputs.jargon_ids, variant.outputs),
    }

def annotate_safety(
    metrics: list[dict[str, object]],
    *,
    fwer_delta: float,
) -> dict[str, object]:
    baseline_fwer = float(metrics[0]["fwer_negative"])
    safe_limit = baseline_fwer + fwer_delta
    safe_indexes = [
        index
        for index, row in enumerate(metrics)
        if row["jargon_false_terms"] == 0
        and float(row["fwer_negative"]) <= safe_limit + EPSILON
    ]
    best_index = min(
        safe_indexes,
        key=lambda index: (
            -float(metrics[index]["jargon_term_recall"]),
            float(metrics[index]["uwer_mix"]),
            float(metrics[index]["fwer_negative"]),
            index,
        ),
    )
    for index, row in enumerate(metrics):
        row["safe"] = index in safe_indexes
        row["is_best_safe"] = index == best_index
    return metrics[best_index]


def false_term_records(
    inputs: ReplayInputs,
    variant: ReplayVariant,
) -> list[dict[str, str]]:
    surfaces = sorted(
        {
            inputs.annotations[row_id]["canonical"]
            for row_id in inputs.jargon_ids
            if "canonical" in inputs.annotations[row_id]
        }
    )
    patterns = {surface: surface_pattern(surface) for surface in surfaces}
    records: list[dict[str, str]] = []
    for row_id in inputs.jargon_ids:
        if "canonical" in inputs.annotations[row_id]:
            continue
        reference = inputs.jargon_refs[row_id]
        repaired = variant.outputs[row_id]
        for surface in surfaces:
            pattern = patterns[surface]
            if pattern.search(repaired) and not pattern.search(reference):
                records.append(
                    {
                        "baseline_final_text": inputs.jargon_finals[row_id],
                        "id": row_id,
                        "reference": reference,
                        "repaired_final_text": repaired,
                        "surface": surface,
                    }
                )
    return records


def miss_coverage(
    variant: ReplayVariant,
    taxonomy_rows: list[dict[str, object]],
) -> dict[str, dict[str, int]]:
    coverage = {
        category: {"hits": 0, "opportunities": 0}
        for category in MISS_CATEGORIES
    }
    for row in taxonomy_rows:
        category = str(row["category"])
        row_id = str(row["id"])
        canonical = str(row["canonical"])
        coverage[category]["opportunities"] += 1
        if surface_pattern(canonical).search(variant.outputs[row_id]):
            coverage[category]["hits"] += 1
    return coverage


def build_variants(inputs: ReplayInputs, vocabulary: Vocabulary) -> list[ReplayVariant]:
    variants = [
        ReplayVariant(
            strategy="BASELINE",
            threshold=None,
            outputs=dict(inputs.jargon_finals),
            repairs={row_id: () for row_id in inputs.jargon_ids},
        )
    ]
    specifications: list[tuple[str, float | None]] = [
        ("RECASE", None),
        ("LEXICAL", None),
        *(("PHONETIC", threshold) for threshold in THRESHOLDS),
    ]
    for strategy, threshold in specifications:
        outputs: dict[str, str] = {}
        repairs: dict[str, tuple[RepairEvent, ...]] = {}
        for row_id in inputs.jargon_ids:
            result = vocabulary.repair(
                inputs.jargon_finals[row_id],
                strategy=strategy.lower(),
                threshold=threshold,
            )
            outputs[row_id] = result.text
            repairs[row_id] = result.events
        variants.append(
            ReplayVariant(
                strategy=strategy,
                threshold=threshold,
                outputs=outputs,
                repairs=repairs,
            )
        )
    return variants


def classify_misses(inputs: ReplayInputs, vocabulary: Vocabulary) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for row_id in inputs.jargon_ids:
        annotation = inputs.annotations[row_id]
        canonical = annotation.get("canonical")
        if canonical is None:
            continue
        text = inputs.jargon_finals[row_id]
        if surface_pattern(canonical).search(text):
            continue

        case_match = alias_pattern(canonical).search(text)
        if case_match is not None:
            rows.append(
                {
                    "best_phonetic_score": None,
                    "best_span": case_match.group(0),
                    "canonical": canonical,
                    "category": "case_only",
                    "id": row_id,
                    "matched_alias": canonical,
                    "transcript": text,
                }
            )
            continue

        alias_hits: list[tuple[int, int, str, str]] = []
        for alias in vocabulary.aliases[canonical]:
            for match in alias_pattern(alias).finditer(text):
                alias_hits.append((match.start(), match.end(), alias, match.group(0)))
        if alias_hits:
            start, end, matched_alias, span = min(
                alias_hits,
                key=lambda item: (-(item[1] - item[0]), item[0], item[2].casefold(), item[2]),
            )
            rows.append(
                {
                    "best_phonetic_score": None,
                    "best_span": span,
                    "canonical": canonical,
                    "category": "lexical_variant",
                    "id": row_id,
                    "matched_alias": matched_alias,
                    "span_end": end,
                    "span_start": start,
                    "transcript": text,
                }
            )
            continue

        score, start, end, span = vocabulary.best_span(text, canonical)
        category = "phonetic_near" if score + EPSILON >= 0.8 else "phonetic_far_or_absent"
        rows.append(
            {
                "best_phonetic_score": round(score, 9),
                "best_span": span,
                "canonical": canonical,
                "category": category,
                "id": row_id,
                "matched_alias": None,
                "span_end": end,
                "span_start": start,
                "transcript": text,
            }
        )
    return rows


def _relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO))
    except ValueError:
        return str(path.resolve())


def _file_record(path: Path) -> dict[str, object]:
    payload = path.read_bytes()
    return {
        "path": _relative(path),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }


def _format_table(metrics: list[dict[str, object]]) -> str:
    header = (
        "  strategy  theta  recall   false_terms  fwer_negative  uwer_jargon  uwer_mix\n"
        "  --------  -----  -------  -----------  -------------  ------------  --------"
    )
    lines = [header]
    for row in metrics:
        marker = "*" if row["is_best_safe"] else " "
        threshold = "-" if row["threshold"] is None else f"{row['threshold']:.2f}"
        lines.append(
            f"{marker} {row['strategy']:<8}  {threshold:>5}  "
            f"{row['jargon_term_recall']:.6f}  {row['jargon_false_terms']:>11}  "
            f"{row['fwer_negative']:.6f}       {row['uwer_jargon']:.6f}      "
            f"{row['uwer_mix']:.6f}"
        )
    return "\n".join(lines)


def write_artifacts(
    output_dir: Path,
    inputs: ReplayInputs,
    variants: list[ReplayVariant],
    metrics: list[dict[str, object]],
    taxonomy_rows: list[dict[str, object]],
    input_paths: dict[str, Path],
) -> str:
    output_dir.mkdir(parents=True, exist_ok=True)
    taxonomy_order = (
        "case_only",
        "lexical_variant",
        "phonetic_near",
        "phonetic_far_or_absent",
    )
    taxonomy_counts = {
        category: sum(row["category"] == category for row in taxonomy_rows)
        for category in taxonomy_order
    }
    best_safe = next(row for row in metrics if row["is_best_safe"])

    payload = {
        "schema_version": 1,
        "inputs": {name: _file_record(path) for name, path in sorted(input_paths.items())},
        "counts": {
            "general_rows": len(inputs.general_ids),
            "jargon_rows": len(inputs.jargon_ids),
            "positive_rows": sum(
                "canonical" in inputs.annotations[row_id] for row_id in inputs.jargon_ids
            ),
            "negative_rows": sum(
                "canonical" not in inputs.annotations[row_id] for row_id in inputs.jargon_ids
            ),
            "distinct_surfaces": len(
                {
                    inputs.annotations[row_id]["canonical"]
                    for row_id in inputs.jargon_ids
                    if "canonical" in inputs.annotations[row_id]
                }
            ),
        },
        "method": {
            "max_window_words": MAX_WINDOW_WORDS,
            "phonetic_blend": "max(grapheme, 0.35*grapheme + 0.65*g2p_lite)",
            "rapidfuzz_version": version("rapidfuzz"),
            "safe_fwer_delta": SAFE_FWER_DELTA,
            "thresholds": list(THRESHOLDS),
        },
        "frontier": metrics,
        "best_safe": best_safe,
        "taxonomy": {
            "baseline_misses": len(taxonomy_rows),
            "counts": taxonomy_counts,
            "phonetic_near_threshold": 0.8,
        },
    }
    (output_dir / "frontier.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    csv_buffer = io.StringIO()
    fieldnames = (
        "best_safe",
        "strategy",
        "threshold",
        "term_hits",
        "term_opportunities",
        "jargon_term_recall",
        "jargon_false_terms",
        "fwer_negative",
        "uwer_jargon",
        "uwer_mix",
        "transcript_sha256",
    )
    writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    for row in metrics:
        writer.writerow(
            {
                "best_safe": "*" if row["is_best_safe"] else "",
                "strategy": row["strategy"],
                "threshold": "" if row["threshold"] is None else f"{row['threshold']:.2f}",
                "term_hits": row["term_hits"],
                "term_opportunities": row["term_opportunities"],
                "jargon_term_recall": f"{row['jargon_term_recall']:.6f}",
                "jargon_false_terms": row["jargon_false_terms"],
                "fwer_negative": f"{row['fwer_negative']:.6f}",
                "uwer_jargon": f"{row['uwer_jargon']:.6f}",
                "uwer_mix": f"{row['uwer_mix']:.6f}",
                "transcript_sha256": row["transcript_sha256"],
            }
        )
    (output_dir / "frontier.csv").write_text(csv_buffer.getvalue(), encoding="utf-8")

    taxonomy_text = "".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        for row in taxonomy_rows
    )
    (output_dir / "miss-taxonomy.jsonl").write_text(taxonomy_text, encoding="utf-8")

    outputs_lines: list[str] = []
    for variant in variants:
        for row_id in inputs.jargon_ids:
            outputs_lines.append(
                json.dumps(
                    {
                        "final_text": variant.outputs[row_id],
                        "id": row_id,
                        "repairs": [event.as_dict() for event in variant.repairs[row_id]],
                        "strategy": variant.strategy,
                        "threshold": variant.threshold,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
    (output_dir / "replay.outputs.jsonl").write_text("".join(outputs_lines), encoding="utf-8")

    table = _format_table(metrics)
    taxonomy_line = ", ".join(
        f"{category}={taxonomy_counts[category]}" for category in taxonomy_order
    )
    best_threshold = (
        "-" if best_safe["threshold"] is None else f"{best_safe['threshold']:.2f}"
    )
    report = (
        f"{table}\n\n"
        f"best_safe={best_safe['strategy']} theta={best_threshold} "
        f"recall={best_safe['jargon_term_recall']:.6f} "
        f"false_terms={best_safe['jargon_false_terms']} "
        f"fwer_negative={best_safe['fwer_negative']:.6f} "
        f"uwer_jargon={best_safe['uwer_jargon']:.6f} "
        f"uwer_mix={best_safe['uwer_mix']:.6f}\n"
        f"safe_fwer_limit={metrics[0]['fwer_negative'] + SAFE_FWER_DELTA:.6f}\n"
        f"taxonomy baseline_misses={len(taxonomy_rows)}: {taxonomy_line}\n"
    )
    (output_dir / "report.txt").write_text(report, encoding="utf-8")
    return report

def write_conditional_artifacts(
    output_dir: Path,
    inputs: ReplayInputs,
    variants: list[ReplayVariant],
    metrics: list[dict[str, object]],
    taxonomy_rows: list[dict[str, object]],
    risky: dict[str, tuple[str, ...]],
    unambiguous: tuple[str, ...],
    dictionary_path: Path,
    offenders: list[dict[str, str]],
) -> str:
    reason_names = ("dictionary_word", "length_le_2", "negative_reference")
    reason_counts = {
        reason: sum(reason in reasons for reasons in risky.values())
        for reason in reason_names
    }
    baseline_fwer = float(metrics[0]["fwer_negative"])
    strict_limit = baseline_fwer + TERM_CONDITIONAL_FWER_DELTA
    hypothesis_rows = [
        row
        for row in metrics
        if row["strategy"] == "LEXICAL"
        or (
            row["strategy"] == "PHONETIC"
            and row["threshold"] is not None
            and float(row["threshold"]) >= 0.85
        )
    ]
    for row in metrics:
        row["meets_recall_target"] = float(row["jargon_term_recall"]) >= 0.75
        row["meets_strict_safety"] = (
            row["jargon_false_terms"] == 0
            and float(row["fwer_negative"]) <= strict_limit + EPSILON
        )
        row["meets_hypothesis"] = (
            row in hypothesis_rows
            and row["meets_recall_target"]
            and row["meets_strict_safety"]
        )

    best_safe = next(row for row in metrics if row["is_best_safe"])
    conditional_false_terms: list[dict[str, object]] = []
    for variant in variants:
        for record in false_term_records(inputs, variant):
            conditional_false_terms.append(
                {
                    **record,
                    "strategy": variant.strategy,
                    "threshold": variant.threshold,
                }
            )
    payload = {
        "schema_version": 1,
        "risk_definition": {
            "dictionary": _file_record(dictionary_path),
            "length_le_2": True,
            "negative_reference_case_insensitive_exact_boundary_match": True,
        },
        "surface_partition": {
            "risky_count": len(risky),
            "unambiguous_count": len(unambiguous),
            "risky": risky,
            "unambiguous": list(unambiguous),
            "reason_counts": reason_counts,
        },
        "strict_safety": {
            "baseline_fwer_negative": baseline_fwer,
            "delta": TERM_CONDITIONAL_FWER_DELTA,
            "limit": strict_limit,
            "best_safe": best_safe,
        },
        "hypothesis": {
            "recall_floor": 0.75,
            "strategies": ["LEXICAL", "PHONETIC@0.85", "PHONETIC@0.90", "PHONETIC@0.95"],
            "passed": any(row["meets_hypothesis"] for row in hypothesis_rows),
        },
        "taxonomy_totals": {
            category: sum(row["category"] == category for row in taxonomy_rows)
            for category in MISS_CATEGORIES
        },
        "frontier": metrics,
        "original_recase_false_terms": offenders,
        "term_conditional_false_terms": conditional_false_terms,
    }
    (output_dir / "term-conditional-frontier.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "surface-risk.json").write_text(
        json.dumps(payload["surface_partition"], indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "false-term-offenders.jsonl").write_text(
        "".join(
            json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
            for row in offenders
        ),
        encoding="utf-8",
    )
    (output_dir / "term-conditional-false-terms.jsonl").write_text(
        "".join(
            json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
            for row in conditional_false_terms
        ),
        encoding="utf-8",
    )

    csv_buffer = io.StringIO()
    fieldnames = (
        "best_safe",
        "strategy",
        "threshold",
        "term_hits",
        "term_opportunities",
        "jargon_term_recall",
        "jargon_false_terms",
        "fwer_negative",
        "uwer_jargon",
        "uwer_mix",
        *(f"{category}_coverage" for category in MISS_CATEGORIES),
        "meets_hypothesis",
        "transcript_sha256",
    )
    writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    for row in metrics:
        record: dict[str, object] = {
            "best_safe": "*" if row["is_best_safe"] else "",
            "strategy": row["strategy"],
            "threshold": "" if row["threshold"] is None else f"{row['threshold']:.2f}",
            "term_hits": row["term_hits"],
            "term_opportunities": row["term_opportunities"],
            "jargon_term_recall": f"{row['jargon_term_recall']:.6f}",
            "jargon_false_terms": row["jargon_false_terms"],
            "fwer_negative": f"{row['fwer_negative']:.6f}",
            "uwer_jargon": f"{row['uwer_jargon']:.6f}",
            "uwer_mix": f"{row['uwer_mix']:.6f}",
            "meets_hypothesis": row["meets_hypothesis"],
            "transcript_sha256": row["transcript_sha256"],
        }
        coverage = row["miss_coverage"]
        for category in MISS_CATEGORIES:
            record[f"{category}_coverage"] = (
                f"{coverage[category]['hits']}/{coverage[category]['opportunities']}"
            )
        writer.writerow(record)
    (output_dir / "term-conditional-frontier.csv").write_text(
        csv_buffer.getvalue(),
        encoding="utf-8",
    )

    output_lines: list[str] = []
    for variant in variants:
        for row_id in inputs.jargon_ids:
            output_lines.append(
                json.dumps(
                    {
                        "final_text": variant.outputs[row_id],
                        "id": row_id,
                        "repairs": [event.as_dict() for event in variant.repairs[row_id]],
                        "strategy": variant.strategy,
                        "threshold": variant.threshold,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
    (output_dir / "term-conditional.outputs.jsonl").write_text(
        "".join(output_lines),
        encoding="utf-8",
    )

    coverage_lines = [
        "  strategy  theta  case-only  lexical  near  far/absent",
        "  --------  -----  ---------  -------  ----  ----------",
    ]
    for row in metrics:
        threshold = "-" if row["threshold"] is None else f"{row['threshold']:.2f}"
        coverage = row["miss_coverage"]
        coverage_lines.append(
            f"  {row['strategy']:<8}  {threshold:>5}  "
            f"{coverage['case_only']['hits']:>2}/{coverage['case_only']['opportunities']:<2}      "
            f"{coverage['lexical_variant']['hits']:>2}/{coverage['lexical_variant']['opportunities']:<2}    "
            f"{coverage['phonetic_near']['hits']:>2}/{coverage['phonetic_near']['opportunities']:<2}  "
            f"{coverage['phonetic_far_or_absent']['hits']:>2}/"
            f"{coverage['phonetic_far_or_absent']['opportunities']:<2}"
        )
    offender_pairs = ", ".join(
        f"{row['surface']}@{row['id']}" for row in offenders
    )
    hypothesis_parts: list[str] = []
    for row in hypothesis_rows:
        threshold = "-" if row["threshold"] is None else f"{row['threshold']:.2f}"
        outcome = "PASS" if row["meets_hypothesis"] else "FAIL"
        hypothesis_parts.append(f"{row['strategy']}@{threshold}={outcome}")
    hypothesis_line = ", ".join(hypothesis_parts)
    best_threshold = (
        "-" if best_safe["threshold"] is None else f"{best_safe['threshold']:.2f}"
    )
    report = (
        f"term_conditional risky={len(risky)} unambiguous={len(unambiguous)} "
        f"strict_fwer_limit={strict_limit:.6f}\n"
        f"{_format_table(metrics)}\n\n"
        + "\n".join(coverage_lines)
        + "\n\n"
        f"best_strict_safe={best_safe['strategy']} "
        f"theta={best_threshold} "
        f"recall={best_safe['jargon_term_recall']:.6f} "
        f"false_terms={best_safe['jargon_false_terms']} "
        f"fwer_negative={best_safe['fwer_negative']:.6f} "
        f"uwer_jargon={best_safe['uwer_jargon']:.6f} "
        f"uwer_mix={best_safe['uwer_mix']:.6f}\n"
        f"hypothesis={hypothesis_line}\n"
        f"original_recase_false_term_pairs={offender_pairs}\n"
    )
    (output_dir / "term-conditional-report.txt").write_text(report, encoding="utf-8")
    return report


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument("--general-corpus", type=Path, default=DEFAULT_GENERAL_CORPUS)
    parser.add_argument("--jargon-corpus", type=Path, default=DEFAULT_JARGON_CORPUS)
    parser.add_argument("--jargon-terms", type=Path, default=DEFAULT_JARGON_TERMS)
    parser.add_argument("--dictionary", type=Path, default=DEFAULT_DICTIONARY)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    inputs = load_inputs(
        args.results,
        args.general_corpus,
        args.jargon_corpus,
        args.jargon_terms,
    )
    surfaces = sorted(
        {
            inputs.annotations[row_id]["canonical"]
            for row_id in inputs.jargon_ids
            if "canonical" in inputs.annotations[row_id]
        }
    )
    vocabulary = Vocabulary(surfaces)
    variants = build_variants(inputs, vocabulary)
    metrics = [score_variant(inputs, variant) for variant in variants]
    annotate_safety(metrics, fwer_delta=SAFE_FWER_DELTA)
    taxonomy_rows = classify_misses(inputs, vocabulary)
    offenders = false_term_records(inputs, variants[1])

    dictionary_words = {
        line.strip().lower()
        for line in args.dictionary.read_text(encoding="utf-8", errors="ignore").splitlines()
        if line.strip()
    }
    negative_references = [
        inputs.jargon_refs[row_id]
        for row_id in inputs.jargon_ids
        if "canonical" not in inputs.annotations[row_id]
    ]
    risky, unambiguous = partition_surfaces(
        surfaces,
        negative_references,
        dictionary_words,
    )
    conditional_vocabulary = Vocabulary(
        unambiguous,
        protected_surfaces=risky,
    )
    conditional_variants = build_variants(inputs, conditional_vocabulary)
    conditional_metrics = [
        score_variant(inputs, variant) for variant in conditional_variants
    ]
    for row, variant in zip(conditional_metrics, conditional_variants, strict=True):
        row["miss_coverage"] = miss_coverage(variant, taxonomy_rows)
    annotate_safety(
        conditional_metrics,
        fwer_delta=TERM_CONDITIONAL_FWER_DELTA,
    )
    report = write_artifacts(
        args.output_dir,
        inputs,
        variants,
        metrics,
        taxonomy_rows,
        {
            "general_corpus": args.general_corpus,
            "jargon_corpus": args.jargon_corpus,
            "jargon_terms": args.jargon_terms,
            "results": args.results,
        },
    )
    conditional_report = write_conditional_artifacts(
        args.output_dir,
        inputs,
        conditional_variants,
        conditional_metrics,
        taxonomy_rows,
        risky,
        unambiguous,
        args.dictionary,
        offenders,
    )
    print(report, end="")
    print()
    print(conditional_report, end="")
    print(f"artifacts={_relative(args.output_dir)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
