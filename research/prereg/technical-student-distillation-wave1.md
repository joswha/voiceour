# Preregistration — technical-student-distillation, Wave 1 (cached teacher-disagreement mining)

Track `technical-student-distillation` (S-tier, workstream `single-model`). Frontier of
record `0ac7514`; contract `research/next-program.md`. Written before any disagreement
count was measured. The commit adding this file is the freeze; the run records that
commit in `wave1/run1/manifest.json`. No endpoint, source, normalization, threshold,
label, or bar may change after that commit; a changed contract requires a new family.

## Question

Can the cached seven-source teacher outputs yield enough source-independent, reference-
verified technical pseudo-targets to justify later single-model distillation, without
running ASR or treating identical homophones as corroboration?

The rejected research teacher used one v3 primary and five assists and reached 295/346
from the program's 161/346 start (`research/final-report.md:10,14-18,24-29`). Its final
diverse-form and alias mechanisms moved 282 to 295 without changing general output
(`research/final-report.md:44-58`). Those gains establish teacher utility, not a training
set. Wave 0 found zero tracked training recipes, QAT implementations, or one-artifact
exporters (`.build/asr-research/next/single-model/technical-student-distillation/wave0/verdict.md:13-26,48-116`),
so this Wave 1 question is deliberately limited to label mining.

## Hypothesis

H1: different decoder sources make different normalized alphanumeric errors around the
same reference technical term often enough to create at least 60 auditable pseudo-target
rows spanning at least four of the five positive domains. The evidence mechanism is the
one frozen by the teacher: heterogeneous misspellings may corroborate a canonical;
repeated identical forms and punctuation-only variants are one observation, not two,
and acronym/camel identifiers require exact evidence (`research/final-report.md:44-58`).

H0: fewer than 60 rows satisfy the fixed rule, or the admitted rows are too concentrated
to span four domains. A large count cannot by itself establish that a student can train,
export, generalize to real speakers, or satisfy Voiceour's product gates.

## Data (immutable inputs; sha256)

Seven sources have complete paired files. Each complete raw file contains 552 unique
records with `{"id", "raw_transcript"}` and its final mate contains the same ordered ids
with `{"id", "final_text"}` (for example,
`.build/asr-research/three-bets/assist/ctc-0p6b-raw.jsonl:1-552` and
`.build/asr-research/three-bets/assist/ctc-0p6b-final.jsonl:1-552`). The 14-file source
budget is exactly:

- `.build/asr-research/three-bets/assist/ctc-0p6b-raw.jsonl` — `81e75235ff609b4dce4916f83f6501529c7aa1562364176fdb80032540627c1d`
- `.build/asr-research/three-bets/assist/ctc-0p6b-final.jsonl` — `ae34ba76c63b0a508adce299f93b83d558760695386bcff3750191388d2f198b`
- `.build/asr-research/three-bets/assist/ctc-1p1b-raw.jsonl` — `ecd71506f1c4d48a5b2af7d5afc1e31af1a5da7c1e2c04eb3b4bef0243c54949`
- `.build/asr-research/three-bets/assist/ctc-1p1b-final.jsonl` — `257cfb34737158374e1fa526665b422f0ff50f2e9cd5f71d6a031b28d96ad87e`
- `.build/asr-research/three-bets/assist/multitalker-0p6b-raw.jsonl` — `fd9daa65a43af2fa87199b375fcc9e5f7a478a7823db049720035addce0f2865`
- `.build/asr-research/three-bets/assist/multitalker-0p6b-final.jsonl` — `a25739d50a93ade53f4adaf13c981bc4aa30a574ff2bd014d73f595476eec489`
- `.build/asr-research/three-bets/assist/realtime-eou-120m-raw.jsonl` — `4d11868482bf190dc2da6f824624511ea7e77bbfc6d40930b9499cd49be20daa`
- `.build/asr-research/three-bets/assist/realtime-eou-120m-final.jsonl` — `69908781770db73913b072be15e61d63bb6b3bb536f72413ae84d91d7941f144`
- `.build/asr-research/three-bets/assist/rnnt-0p6b-raw.jsonl` — `c5e675471e401e11e65bef7663b66b2a973bff5621ee29724ce0f18a29551bac`
- `.build/asr-research/three-bets/assist/rnnt-0p6b-final.jsonl` — `ef829d2fd0a55b63435456f646a6575904b76436b652da5ea0f668ced3b4bcc6`
- `.build/asr-research/three-bets/assist/rnnt-1p1b-raw.jsonl` — `e98fd1ec1da8ab157397b6ba15d6d4435097c8c1cacf9aea0229a90934e02686`
- `.build/asr-research/three-bets/assist/rnnt-1p1b-final.jsonl` — `2dae85cbef003a360d3217960b028ebe7054337810370d59d0b5c7f5a776ad2c`
- `.build/asr-research/three-bets/assist/unified-0p6b-raw.jsonl` — `db7e2666f95f1c42fe431d2034a8fb8c08d77a9f0be1e08e2d14971569fefa79`
- `.build/asr-research/three-bets/assist/unified-0p6b-final.jsonl` — `20bc46e6a493e60320ae3165ae0d5c8d7e2d2d5a17cbd2c62e59d7345bb67031`

The two `hybrid-*-raw.jsonl` files lack final mates, and
`old1p1b-general-final.jsonl` lacks a raw mate and jargon rows. They are excluded before
measurement; no incomplete source is silently promoted.

Other run inputs:

- `.build/autoresearch/jargon.2.results.jsonl` — one `bench_meta` plus 456 `#j0` rows (`.build/autoresearch/jargon.2.results.jsonl:1-457`); `43c6593e29214bc4433472a625dff1e264b5864102a3221f82538ac73c7b61a8`
- `.build/autoresearch/general.results.jsonl` — one `bench_meta` plus four deterministic passes over 96 ids (`.build/autoresearch/general.results.jsonl:1-385`); `73b4be67aab45da787add8c9e4b4beadeb45326904b0dded57be6e95d21357e1`
- `benchmarks/data/jargon/manifest.jsonl` — id, reference, audio path and audio sha256 for 456 rows (`benchmarks/data/jargon/manifest.jsonl:1-456`); `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`
- `bench/autoresearch/corpus.manifest.jsonl` — id, reference and audio sha256 for 96 general controls (`bench/autoresearch/corpus.manifest.jsonl:1-96`); `885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749`
- `bench/autoresearch/jargon.terms.json` — 346 positive row annotations in five domains plus 110 negatives (`research/CONTEXT.md:86-90`); `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`
- `bench/autoresearch/repair.vocabulary.json` — active/protected surfaces, ordinary words and shipped `.95` (`bench/autoresearch/repair.vocabulary.json:234461-234651`); `650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8`
- `bench/autoresearch/replay_repair.py` — frozen candidate generator and event schema; `b2a4360046ee614af4ef81f8bc323e1311cba11b2db41c6cbd0a3c734c7f6767`
- `Sources/VoiceourBench/BenchMain.swift` — frozen evidence normalization and source-distinct rule; `06615df4cdddc80d321cb1c190cc69025f681235c575e68f119709908907ee46`
- `research/final-report.md` — teacher and source-independence contract; `87c55e435d01b58544209ae00172105906f847544880562764de211c6f734622`
- `research/next-program.md` — artifact, metric, gate and holdout contract; `7ae119c644b01e0d3c3718ab6bd5b4d5ceb6e462214339f7f417d8a03d15a98f`
- `research/CONTEXT.md` — frozen corpus composition and synthetic-data warning; `6e2667306f684d314d9337f672da84cd434f1886defe0d86508a606d599729d5`
- `.build/asr-research/next/single-model/technical-student-distillation/wave0/verdict.md` — blocking verdict; `d650381474bbb11a0fa531367f5a211907869242f45cd42ceb95d0952ba62c05`

No audio is decoded, no model is loaded, no harness runs, and no file above is modified.
The run is cached-evidence, CPU-only Python 3.12 in `bench/.venv`; it downloads nothing.

## Sources (fixed; whole source-selection budget)

The file stem is the source identity. The exact model/revision fields written to every
record are frozen here:

| source_id | model_id | model_revision |
|---|---|---|
| `ctc-0p6b` | `nvidia/parakeet-ctc-0.6b` | `ad09ba1cc62743fbc9814de5d2016fca9096485a` |
| `ctc-1p1b` | `nvidia/parakeet-ctc-1.1b` | `20e63a0fed6aedba145b74b826dbd41df0941730` |
| `multitalker-0p6b` | `nvidia/multitalker-parakeet-streaming-0.6b-v1` | `8749fc71fd6e2d88ef230159bbf2aea69b524ee1` |
| `realtime-eou-120m` | `nvidia/parakeet_realtime_eou_120m-v1` | `a7e2b4629593dce0ec19f600e00e9904353fda2d` |
| `rnnt-0p6b` | `nvidia/parakeet-rnnt-0.6b` | `1b6b548f70b93d2410c3d13cc0654cab300f06ef` |
| `rnnt-1p1b` | `nvidia/parakeet-rnnt-1.1b` | `2acc4c61eede2f52ddefe74935de1930a9064d4a` |
| `unified-0p6b` | `nvidia/parakeet-unified-en-0.6b` | `fe53cd885760c96b6a5f51a0bfd362cb4584a98b` |

The cached rows do not embed revisions, so the table is a frozen source label, not a
claim that the model bytes can be reconstructed from these outputs. Output-file digests
are the evidentiary pins. All seven sources participate; no subset, weight, family vote,
or eighth source is tried.

## Candidate generation (fixed)

1. Verify every digest and schema, exact id-set equality across the 14 paired files, and
   equality to the 456 jargon plus 96 general manifest ids. Any mismatch aborts the run.
2. Strip only the terminal `#j0` from jargon frontier ids. For general, require passes
   `#p0` through `#p3` and byte-identical `raw_transcript` and `final_text` per base id;
   retain `#p0`. No majority vote is allowed.
3. Load active and protected surfaces plus `ordinary_words` from the pinned repair
   vocabulary. Run `Vocabulary.repair(raw_transcript, strategy="phonetic",
   threshold=.80)` independently for every source row. Record every returned event; use
   only `kind="phonetic"`. The `.80` operating point is inherited unchanged from the
   teacher (`research/final-report.md:44-49`); `.95`, `.85`, `.75`, and any sweep are out.
4. Normalize an event's `before` form exactly like `normalizedEvidenceForm`: split
   Unicode scalars at every non-alphanumeric scalar, lowercase each token, and join with
   one ASCII space (`Sources/VoiceourBench/BenchMain.swift:373-445`). Thus casing and
   punctuation alone never manufacture diversity.
5. A relaxed canonical has source-independent support only if two events have the same
   `after` canonical, different `source_id`, nonempty normalized forms, and unequal
   normalized forms. Sources agree on the canonical; their evidence forms must differ.
   Two sources saying the same normalized homophone remain one observation.
6. A Titlecase canonical additionally requires at least one supporting normalized form
   that is not an ordinary phrase. Ordinary-phrase and suffix handling mirror
   `BenchMain.swift:458-479`; no new dictionary or morphology is introduced.
7. A canonical containing a symbol, two or more uppercase letters, or an uppercase
   letter after its first letter is exact-only. It is never admitted by phonetic score:
   two distinct sources must contain the exact case-sensitive bounded canonical in raw
   text. The sole alias exception is the frozen `letter + at least two spoken "plus"`
   rule for terms such as `C++`, which requires the same bounded spoken alias in two raw
   sources; `C#`/“sharp” stays excluded (`research/final-report.md:46-52`).
8. Run the same blind consensus extraction on all 552 rows and every active canonical.
   A consensus whose reference lacks that exact bounded canonical is an unsafe consensus
   audit event, never a target. This includes the 110 jargon negatives and 96 general
   controls; references may reject labels but never help form source consensus.
9. For each of the 346 annotated positive rows, admit at most its one annotated canonical
   iff the blind rule supports it, the reference contains it exactly, and the frozen
   frontier `final_text` contains it exactly. Source outputs, not the reference or
   frontier, must have formed the consensus. Sort records by audio id.

No learned model, feature vector, split, fit, probability cut, or hyper-parameter search
exists. The procedure above is the entire model/threshold budget. There is consequently
no training-only operating-point selection, repeated random split, or paired comparison;
no permutation test is claimed or applicable.

## Pseudo-target record (fixed)

`teacher-disagreements.jsonl` has one object per admitted audio row with: `id`,
`audio_sha256`, `reference`, `canonical`, `domain`, `frontier_raw_transcript`,
`frontier_final_text`, `rule` (`diverse_phonetic`, `exact_identifier`, or
`spoken_plus_alias`), `supporting_normalized_forms`, and `sources`. Each `sources` item
contains `source_id`, `model_id`, `model_revision`, `raw_transcript`, `final_text`, and
the exact supporting repair event or bounded exact match. It also carries `decision` with
supporting source ids, source count, reference check, frontier check, and `admitted=true`.
No audio path substitutes for `audio_sha256`; no source text is reconstructed.

## Evaluation (fixed)

- **Primary endpoint:** `student_pseudo_targets`, the number of admitted one-record-per-
  audio positive rows. `student_pseudo_target_domains` is the number of represented
  domains among `apple`, `cloud`, `dataweb`, `langs`, and `security`
  (`research/CONTEXT.md:86-90`).
- **Meaningful effect:** `student_pseudo_targets >= 100` and
  `student_pseudo_target_domains >= 4`: enough admitted targets, across most domains, to
  make a distillation data plan from the teacher's 134 net fixes worth pinning a toolchain
  for.
- **Kill:** `student_pseudo_targets < 60`. A count between 60 and 99, or one at or above
  100 spanning fewer than four domains, fails the meaningful effect without killing: it is
  recorded as `weak` and the data plan then depends on the real-speaker corpus for the
  balance. The numeric thresholds are not lowered after the freeze.
- **Secondaries:** counts by domain and rule; supporting-source-count distribution;
  `student_pseudo_target_abstention_rate = 1 - student_pseudo_targets / 346`;
  `student_unsafe_consensus_rows` and its rate over the fixed 206 control rows; and every
  abstention reason. These are reported and never promoted to primary.
- **Uncertainty:** percentile bootstrap over the 346 positive audio rows, `B=10,000`,
  seed `20260830`, using `numpy.random.Generator(numpy.random.PCG64(20260830))` and
  NumPy's linear 2.5th/97.5th percentiles. Each resample draws 346 rows with replacement
  and recomputes target count, abstention rate, and represented-domain count. The row is
  the resampling unit because the endpoint is one audio-record target and each row can
  contribute at most once; the two synthetic prompts per canonical are not collapsed.
- If `student_unsafe_consensus_rows = 0`, report the exact one-sided 95% Clopper–Pearson
  upper bound `1 - .05**(1/206)` for its row rate. This closed form needs no SciPy. A
  nonzero audit count is reported directly and is never relabeled as a zero-count bound.

## What this pilot cannot show

A pass yields distillation **targets only**. The jargon audio is synthetic, one-voice
optimization evidence, and the general rows are term-free (`research/CONTEXT.md:83-93`);
this cannot show learnability, loss behavior, student recall,
real-speaker performance, calibration, false-activation safety, determinism, latency,
footprint, installed size, or export validity. It cannot license a harness run or a fresh
holdout. Synthetic `jargon_term_recall` remains development evidence; only
`real_speaker_recall` may support promotion (`research/next-program.md:315-327`).

Training remains blocked on both (1) a licensed, speaker/session-disjoint real-speaker
technical corpus with immutable train/calibration/sealed-test manifests and (2) a pinned
Apple-compatible training/export toolchain. The toolchain decision must name the training
framework, exact framework and dependency versions, trainable checkpoint and tokenizer
pins, deterministic export path to exactly one Voiceour-loadable GGUF artifact, and the
QAT scheme: target q8 format, tensor/channel granularity, scale and rounding rules,
straight-through estimator, and schedule. No local torch, NeMo, Core ML Tools, QAT
implementation, or one-GGUF exporter is available in the pinned environment
(`wave0/verdict.md:88-116`).

## Artifacts and command

Root:
`/Users/vlad/Desktop/voiceoour/.build/asr-research/next/single-model/technical-student-distillation/wave1/`.
It contains `prereg.md` (this file plus freeze commit) and `verdict.md`; `run1/` contains
`manifest.json`, `metrics.jsonl`, `rows.jsonl`, `teacher-disagreements.jsonl`,
`mine_teacher_disagreements.py`, and `command.txt`. `rows.jsonl` carries all 552 row-level
decisions and audit events; `metrics.jsonl` has one record per declared metric using run
`technical-student-distillation/wave1/1`. The manifest records all required absent
harness pins as `native`, `none`, or `0`, every digest above, environment keys, seed,
threshold, and prereg commit (`research/next-program.md:146-192`).

The single command recorded verbatim is:

```sh
cd /Users/vlad/Desktop/voiceoour && bench/.venv/bin/python .build/asr-research/next/single-model/technical-student-distillation/wave1/run1/mine_teacher_disagreements.py --assist-dir .build/asr-research/three-bets/assist --jargon-frontier .build/autoresearch/jargon.2.results.jsonl --general-frontier .build/autoresearch/general.results.jsonl --jargon-terms bench/autoresearch/jargon.terms.json --jargon-manifest benchmarks/data/jargon/manifest.jsonl --general-manifest bench/autoresearch/corpus.manifest.jsonl --repair-vocabulary bench/autoresearch/repair.vocabulary.json --out .build/asr-research/next/single-model/technical-student-distillation/wave1/run1
```

This is not a decode/download/training/GPU/ANE step. Any later such step is explicitly
**parent-serialized, exclusive hardware** and must have a separately frozen exact command.

## Stop rule

One cached CPU run, `run1`, then stop. No source removal, extra model, threshold change,
normalization change, reference exception, domain rebalance, or retuning against these
rows is allowed. A digest, schema, id-set, duplicate-id, pass-identity, audio-hash, or
reference-integrity failure aborts before measurement and blocks the pilot. Once endpoint
metrics are emitted, failure of the meaningful effect stops this candidate family; a
failed pilot is not repaired with another run. Training remains blocked even if Wave 1
passes.