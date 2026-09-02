# Three-bets final research report

Date: 2026-09-02. Branch: `autoresearch/research-all-those-three-bets-you-have-unlimited-20260831`.
Canonical measurement command: `bash autoresearch.sh`.

## Executive verdict

| bet | verdict | strongest verified result |
|---|---|---|
| Contextual vocabulary binding | **Research success; product ensemble rejected** | jargon recall .465318 → **.852601** (161→295/346), mix U-WER .045995 → **.028068**, general U-WER .030725 unchanged at the final frontier, corrected false rows 0 |
| ANE / heterogeneous execution | **Mechanism success; promotion blocked** | 6/8/15 s CoreML ladder reduced measured compute energy 444.6→187.5 J (−57.8%); contamination-resistant ABBA ratio .5679 (−43.2%) |
| Quantization / margin theory | **q8 storage and tail success; mixed frontier closed** | whole q8 non-inferior (+.000307 U-WER), tied/faster on the current toolchain, −587 MB download; CPU-tail q8 cut tail weights 25.73→13.67 MB with equal-or-better accuracy |

The final research configuration is not the shipping app. It is a teacher/error-mining
stack behind `voiceour-bench`: v3 primary, five concurrent Parakeet-family assists,
three CoreML encoder tiers, CPU q8 tail, strict repair, guarded diverse-form relaxed
repair, and an exact pre-clean C++ alias shelter. Voiceour and Syncour still consume the
single primary transcript.

## Final measured configuration

Post-review harness verification, M4 Pro, macOS 26.6.2:

- jargon term recall **.852601 (295/346)**; 51 misses;
- `uwer_mix` **.028068**, `uwer_general` **.030725**, `uwer_jargon` **.025410**;
- corrected jargon false rows **0**; deterministic pair; error rows 0;
- inference p50/p95 **127.5/174 ms**, RTFx **155.21**;
- peak physical footprint **310 MB**, peak RSS **219 MB**;
- final transcript hashes: jargon `41c27a19460bfdea0f382d2cb4d181cb35a057bd40204cff9dc4207354e5ae53`, general `6607b2326b40254f37b7332262b3d7009272e9e811a94ffc493e8dbc6229a229`.

The low process footprint does not represent installed bytes: clean file-backed mappings
are excluded from those peaks. Six raw GGUFs total 9.27 GB; with derived arenas and
CoreML tiers the measured research installation is about 19.9 GB.

## Bet 1 — contextual vocabulary binding

### What worked

1. Frozen deterministic `.95` lexical/phonetic repair with ordinary-span and protected-
   surface guards.
2. Exact-surface whole-transcript arbitration over v2, 1.1B, hybrid TDT-CTC 1.1B,
   unified 0.6B, and multitalker 0.6B assists. Concurrent assist contexts recovered
   p95 from ~209 to ~170–185 ms without output change.
3. Guarded diverse-form repair: a second `.80` pass is evidence only. A relaxed term
   requires different normalized alphanumeric spellings from different decoder sources;
   repeated forms or punctuation-only variants are one observation. Acronyms/camel
   identifiers require exact evidence; Titlecase terms require at least one nonordinary
   form. A candidate carrying any unapproved relaxed repair is rejected wholesale.
   Strict product repair remains `.95`.
4. Pre-clean spoken alias shelter for mechanically derived `letter + >=2 plus` terms.
   Two raw sources must say the bounded alias before `C plus plus` becomes `C++`.
   `C#`/“sharp” is deliberately excluded.

The last two mechanisms raised 282→295 hits without changing general output in runs
133–134. They fix source defects rather than hiding scorer symptoms: heterogeneous
misspellings provide repair evidence; identical homophones do not; symbol shelter runs
before cleanup can collapse the evidence. A final independent review then hardened
source independence, punctuation normalization, and unapproved-event rejection with
three red→green regression tests; the post-review harness result is the final authority.

### Safety sequence

Safety failures were treated as invalidations, not explained away:

- Earnings22 shard 0, strict five-assist stack: 1 genuine unsafe `Credit Swift` for
  Credit Suisse in 646 narrowband rows, plus 2 true-audio/reference-truncation cases.
- VoxPopuli EN, strict final stack: 0 fires / 1,826 wideband rows.
- Unguarded relaxed consensus failed on fresh Earnings22 shard 1: `IAM` from
  `I'm`/`am`; `.80` also produced `CALayer` from `color`/`colour`.
- Shape-only guard failed on fresh People's Speech shard 0: `radios`/`radius`→`Redis`
  once in 3,676 rows.
- Final two-guard `.80` rule passed untouched People's Speech shard 1: **0 fires /
  3,603 rows**, strict and diverse U-WER both .1785309668, deterministic/error-free.
- `.75` was rejected on untouched shard 2: ordinary `run`/`runs`→`runc` once in
  3,551 rows. Run 132 is flagged and the threshold is `.80`.

The final C++ shelter is mechanically exact and fired on only the two intended frozen
rows; its planned extra shard was cancelled to converge promptly. It therefore has
strong unit/frozen evidence but not a separate fresh-holdout claim. Across 10,830
already-decoded People's Speech rows from shards 0–2, the exact `C plus plus` consensus
pattern occurred zero times, so the shelter introduced no additional real-speech fire
in that retrospective scan.

### What failed

Flat/token-trie bias, forced scoring, k-best through 8, cached DAG rewalk, model-capacity
replacement, standalone CTC/RNNT variants, Whisper, pruning, speed perturbation,
longer-surface arbitration, thread-count tuning, generic quorum, and source-order
permutations. External independent pilots also stopped early:

- Fun-ASR Nano: one GitLab rescue, but an unsafe `Xcode` fire for spoken `eksctl`.
- Moonshine Medium Streaming without bias rescued only SAML. Its supported keyterm
  mode reached 301/346 on the full frozen projection, but was rejected: jargon U-WER
  regressed .025410→.027664, 8/14 adopted rows worsened, and 6 taught surfaces were
  unsupported (including QUIC for queues, C++ for CI/secret, and CUDA for securely).
- Nemotron Speech Streaming: one monorepo rescue already subsumed by diverse repair;
  RTFx 84.67 and ~2.05 GB process footprint missed product bars.

All 51 run134 misses lack an exact canonical in every Parakeet source. Remaining broad
phonetic lowering is unsafe; `.70` retained no extra recall and produced unrelated
technical insertions. Decode-side candidate creation is closed for this model family.

## Bet 2 — ANE / heterogeneous execution

The FastConformer encoder can run through CoreML while the TDT tail stays native. The
key numerical finding was a padding contract mismatch (reflect vs zero), not generic
float precision. Exact native transcript identity was unattainable, but the corrected
path was quality-non-inferior and deterministic.

Surviving implementation:

- native mel + CoreML encoder vendor seam (patch 0016);
- palettized 6-bit 6/8/15 s `CPU_AND_NE` tiers, native fallback above 15 s;
- CPU tail (0017), q8 tail repack (0019), persistent pool;
- lazy, lock-free tier priming on preload and post-idle reload.

Measured energy fell 57.8% in the ladder experiment; robust ABBA showed 43.2%. The
later composite ladder+CPU/q8-tail ratio reached .3053 with p95 179 ms and RTFx 190.7.
Do not call this ANE-only savings.

Promotion remains blocked by a second Apple-Silicon SoC, hosted/pinned tier artifacts,
cold-specialization readiness, and app wiring. One standard tier (~459 MB) is the
credible product compromise; the three-tier research set adds ~1.36 GB.

## Bet 3 — quantization and margin stability

The old claim that q8 is 7–19% slower is stale on the current OS/toolchain. Official
whole-model q8 was quality-non-inferior, p95 205.75 vs 208 ms, and reduced the download
by 587,140,200 bytes. It remains a footprint choice, never an accuracy claim.

The mixed loader proved provenance matters: the official q8 derives from original F32;
re-quantizing the published f16 changes 10,718,248 payload bytes. Encoder-FFN Q6 was
killed because p95 ratio 1.0349 exceeded its 1.03 gate despite acceptable accuracy.
Margin harvests locate local q8 flips well (token AUROC .995–.998), but cannot predict
semantic harm (flip-direction AUROC .27); 86–89% of path flips still recover the same
text. Margin-only mixed-precision selection is therefore closed.

The shippable independent result is CPU-tail-only q8: 25.73→13.67 MB tail weights,
accuracy equal-or-better, retained behind explicit configuration. Whole-model q8
default promotion still needs the preregistered cross-SoC/OS and real-speaker matrix.

## Product decision

Do **not** ship the six-model research ensemble. It conflicts with the one-resident-
artifact contract, exceeds the 6.4 GB cache budget, hides multi-second first-use assist
loads, lacks transactional multi-artifact acquisition/provenance, and diverges from
Syncour. The .852601 score assumes the full 173-surface taught vocabulary; it is not a
normal-user glossary estimate.

Preserve the ensemble as a benchmark teacher. Product work should independently promote
ANE/tail-q8 after their gates, or distill/fine-tune a single pinned technical student.
A student must meet the same one-artifact, fresh-safety, p95≤230, RTFx≥100, deterministic,
and general-U-WER contracts.

## Reproduction and evidence

- Harness: `bash autoresearch.sh`.
- Focused arbitration tests: `swift test --filter AssistArbitrationTests`.
- Full repository gate: `make check`.
- Bet details: `research/bet1-contextual-decoding.md`, `research/bet2-ane-encoder.md`,
  `research/bet3-quantization.md`.
- Promotion gates: `research/bet2-promotion-packet.md` and the q8 preregistration named
  in `research/bet3-quantization.md`.
- Large corpora, raw model outputs, preregistrations, and sealed verdicts live under
  `.build/asr-research/three-bets/`; they are local evidence, not distributable source.
