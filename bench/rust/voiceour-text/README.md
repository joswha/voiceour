# voiceour-text — bet B3: the post-ASR text stage in Rust vs Swift

Benchmark-only. Nothing here is linked into the app; `Sources/` and `Tests/` are untouched.

- `bench/rust/voiceour-text/` (this crate, own cargo workspace): a Rust port of the production
  text path (`src/{literal,cleanup,glossary,vocabulary,repair,pipeline}.rs`), its Unicode layer
  (`src/uni.rs`, `src/icu.rs`, generated `src/tables.rs`), the `text-bench` CLI, the C ABI
  `libvoiceour_text.dylib` (`src/ffi.rs`, prefix `vtx_`), `scripts/b3-parity.sh` and
  `scripts/b3-timing.sh`.
- `bench/rust/swift-text-harness/` (nested SwiftPM package, depends on the root package by path,
  product `VoiceCore`): `swift-text-bench`, which runs the **shipped** VoiceCore code in release,
  the Rust port in the same process (`RustFFI.swift`), and the optimized Swift copies
  (`Optimized*.swift`, namespace `Optimized`).

## The production per-utterance path

`DictationCoordinator.processStop` (`Sources/Voiceour/TranscriptProcessingPipeline.swift:153`):

1. `VocabularyCompiler.compile(persistent: settings.glossary, ephemeral: [])`
   (`TranscriptProcessingPipeline.swift:196-201`; `Sources/VoiceCore/Vocabulary.swift:86`, `limit` 100,
   `now: Date()`). Compiled **once per utterance**, before ASR. It caps the active snapshot at 100
   terms (priority terms first, then per-source quotas, then backfill).
2. `LiteralComposition.apply(rawTranscript)` (`TranscriptProcessingPipeline.swift:214`;
   `LiteralComposition.swift:2`).
3. `CleanupEngine.clean(composed, glossary: activeTerms)` when `settings.cleanupEnabled` (default
   `true`) (`:215-216`; `CleanupEngine.swift:6`): `normalize` -> fragile-surface scan -> filler removal ->
   adjacent-repeat collapse -> sentence-case repair -> `Glossary.canonicalize` (`Glossary.swift:58`,
   one `NSRegularExpression` per alias per term **per call**) -> trim. Production passes no repair
   engine here.
4. `repairEngine(for: activeTerms)` (`:218`, defined `:61-80`): cached by the array of active
   canonicals; on a miss it runs `RepairVocabulary.fromActiveTerms(_, ordinaryWords:
   RepairVocabulary.bundledOrdinaryWords)` (`VocabularyRepair.swift:38`; the 234,456-word set is a
   `static let`, loaded once per process, `:14`) and `VocabularyRepairEngine(vocabulary:)` (`:156`).
5. `engine.repair(cleaned).text` (`:219`; `VocabularyRepair.swift:238`): protected spans, lexical
   alias matches, then a phonetic window scan (1-5 tokens x every surface x its profiles).

Not on the stop -> delivery path: `Phonetics` is only called by `CandidateRetrieval`
(`CandidateRetrieval.swift:134`), which runs in a detached utility task after insertion
(`TranscriptProcessingPipeline.swift:330-340`). It is therefore not ported.

## Port and equivalence method

The port mirrors the Swift algorithm function by function: the same passes, per-call alias
derivation, per-call matcher construction in `canonicalize`, and the same window scan. Where
Swift semantics are subtle the port reproduces the observed behaviour:

- **Unicode properties**: `swift-text-bench tables` asks the production runtime about every scalar
  (Swift `Character` properties and case mapping, Foundation `CharacterSet`s, CoreFoundation
  folding and compatibility decomposition, ICU 78.1 simple/full case folding, `\s`, the
  case-insensitive `[A-Za-z0-9_]` class) and writes `src/tables.rs`. Grapheme clusters and
  canonical equivalence use `unicode-segmentation` 1.13.3 and `unicode-normalization` 0.1.25,
  both Unicode 17.0, the version of the Swift 6.4 stdlib and of ICU 78.1 on macOS 27.0.1.
- **Semantics confirmed by probes** (`swift-text-bench probe crlf|contains|misc`): `contains("/")`,
  `hasPrefix("-")` and `split(separator:)` are Character-wise (0 mismatches over all scalars);
  `trimmingCharacters`/`components(separatedBy:)` are scalar-wise; `Range(NSRange, in:)` accepts
  scalar-aligned offsets inside a Character; `lowercased()` applies no final-sigma context;
  `replacingOccurrences(of: "\r\n")` refuses a match followed by a CoreFoundation non-base scalar
  (Grapheme_Extend + U+1F3FB-1F3FF, minus Apple PUA F870-F89F), which cannot change `normalize`'s
  output because both CR and LF are separators there.
- **NSRegularExpression**: the `regex` crate cannot express the alias pattern (no look-around) and
  folds case simply, while ICU folds literal runs fully (`ß` matches `ss`). `src/icu.rs` matches the
  alias, token and `canonicalTokens` patterns by hand, following ICU's compiled program
  (`URX_ONECHAR_I` simple folding vs `URX_STRING_I` full folding, greedy `\s+` with backtracking,
  look-behind/ahead on the case-closed class, leftmost non-overlapping matches).
- One harness pitfall found: `JSONSerialization` drops a string's leading U+FEFF on read, so the Swift
  harness decodes all inputs with `JSONDecoder` (which keeps it).

### Evidence (2026-10-16, macOS 27.0.1 26A434, Apple M4 Pro)

- End to end, `scripts/b3-parity.sh 4`: **131,994 / 131,994 cases identical** (0 diffs) across 24
  (cases, glossary) pairs, comparing `composed`, `cleaned`, output text, its SHA-256, and every repair
  event (offsets, before/after, kind, score bit pattern) plus the compiled snapshot and repair
  partition: fixtures 3 x 68, realistic 9 x 1,310 (3 realistic + 6 scaling glossaries), fuzz
  12 x 10,000 (each with its own fuzz glossary). 35,456 outputs were changed by repair (26,595
  phonetic, 27,040 canonical, 4,729 alias events), 105,650 inputs are non-ASCII. The same run
  compares the optimized Swift copies (`swift-opt`, `swift-opt-repr`, see Attribution) with the
  shipped code: also **131,994 / 131,994** each, snapshot and partition included.
- Primitive oracle (`oracle-gen` 200,000 rows -> `swift-text-bench oracle` -> `oracle-check`):
  27 fields per row (graphemes, Character properties, lower/upper/fold, NFKD-ASCII, `==`/`<`,
  hasPrefix/contains, trims and splits, alias and token `NSRegularExpression` matches,
  canonicalTokens, `derivedAliases`, `aliasCanGeneralize`, normalize, LiteralComposition,
  clean, canonicalize): **0 disagreements**.

## Inputs (`text-bench gen-inputs`, seeded, repository data only)

Written to `.build/rust-bench/b3/inputs/`:
- `cases/realistic.jsonl`: 1,310 unique raw transcripts: non-fake `raw_transcript` rows of
  `benchmarks/results/*.results.jsonl` plus `ref.text` of `.build/rust-bench/dumps/*/index.jsonl`
  (present at generation time). Re-run `gen-inputs` if the dumps change.
- `cases/fixtures.jsonl`: `fixtures/text/cleanup_pairs.json` inputs and the VoiceCore test strings.
- `glossaries/default7.json` (`Settings.defaultGlossary`), `user-jargon.json` (default7 +
  `bench/autoresearch/jargon.terms.json` canonicals as a word-list import: `manualImport`,
  unprotected), `repair-vocab.json` (`repair.vocabulary.json` surfaces + protected surfaces as
  explicit corrections).
- `glossaries/scale-{0,10,50,100,1000,5000}.json`: jargon terms interleaved with synthetic terms
  (spoken aliases, labeled confirmed/rejected aliases, all four sources, tombstones, ordinary-word
  hard negatives). Production compiles at most 100 active terms, so 1,000 and 5,000 change the
  compile stage and which 100 terms are active, not the text stage's term count. Every scale
  glossary is a prefix of one pool, so adding a size changes none of the others. Active terms:
  scale-0 0, scale-10 10, scale-50 50, scale-100 98 (two tombstoned), scale-1000/5000 100.
- `cases/fuzz-NN.jsonl` + `glossaries/fuzz-NN.json`, 12 x 10,000: mixed scripts, combining marks,
  emoji/ZWJ/flags, special spaces and invisibles, CR/LF, punctuation, numbers, spelled letters,
  fillers, stutters, literal commands, planted glossary surfaces and near misses; glossaries with
  Unicode/symbol canonicals, case policies, fragile surfaces, non-generalizing aliases, ambiguity.

## Build

```sh
(cd bench/rust/voiceour-text && cargo build --release)            # lto=fat, codegen-units=1; also
                                                                  # target/release/libvoiceour_text.dylib
(cd bench/rust/swift-text-harness && swift build -c release)
RUST=bench/rust/voiceour-text/target/release/text-bench
SWIFT=$(cd bench/rust/swift-text-harness && swift build -c release --show-bin-path)/swift-text-bench
$RUST gen-inputs                                                  # -> .build/rust-bench/b3/inputs
bench/rust/voiceour-text/scripts/b3-parity.sh 4                   # equivalence, exits 1 on any diff
$SWIFT tables bench/rust/voiceour-text/src/tables.rs              # regenerate tables (after an OS update)
```

## In-process pairing: arm `rust-ffi`

`libvoiceour_text.dylib` (`src/ffi.rs`, C ABI prefix `vtx_`, contract in the module doc) exports
`vtx_abi_version` (1), `vtx_arms` (`"rust-ffi"`), `vtx_engine_new` (glossary file bytes +
ordinary-words path; compiles the snapshot and builds the cached engine, as a warm process has),
`vtx_run` (stage 0 `text`, 1 `compile`, 2 `engine`, 3 `echo`; UTF-8 in, UTF-8 out in a caller
buffer, required length returned on overflow, `vtx_last_output` fetches it without re-running),
`vtx_release` (drops the last result outside the timed region) and `vtx_engine_free`. Panics are
caught and reported through `err`.

`swift-text-bench bench --arms swift,swift@aa,rust-ffi,swift-opt,swift-opt-repr` runs every arm in
one process on every row. Arm order rotates per row (cyclic from `(pass + position) mod arms`,
reversed every other cycle; with two arms this is the old forward/reverse alternation, and
`text-bench` uses the same order). `--rust-lib` overrides the dylib path. Timed units:

| arm | text | compile | engine |
| --- | --- | --- | --- |
| `swift` | `ProductionTextPath.process` (VoiceCore) | `VocabularyCompiler.compile` | `fromActiveTerms` + `VocabularyRepairEngine.init` |
| `swift-opt`, `swift-opt-repr` | `Optimized.TextPath.process` | `Optimized.compile` (`-repr`: VoiceCore) | `Optimized.partition` + `Optimized.RepairEngine.init` |
| `rust-ffi` | `RustTextEngine.run`: the String's UTF-8 view into `vtx_run` (Rust validates UTF-8, runs the port, copies its output out), then `String(decoding:)` | same call; Rust also joins the ids | same call; Rust also joins the surfaces |

So `rust-ffi` pays both marshalling directions, plus building its `&[&ProtectedTerm]` snapshot on
every call. `--stage boundary` (rust-ffi arms only, `vtx_run` stage 3) times that crossing with no
work inside. Dev smoke: p50 **0.08 µs** per realistic row, p90 0.19 µs.

## Attribution

### Profiles (dev; `sample` at 1 ms, release builds, one arm per process, shared machine)

Text stage, `user-jargon` (100 active terms), the first 300 realistic rows. Main-thread shares;
inclusive unless marked self:

| Swift, VoiceCore (8,029 samples) | | Rust port (8,729 samples) | |
| --- | ---: | --- | ---: |
| `VocabularyRepairEngine.repair` | 79.2% | `VocabularyRepairEngine::repair` | 90.9% |
| `normalizedLevenshteinSimilarity` (self 33.2%) | 64.7% | `normalized_levenshtein_similarity` (self 69.7%) | 84.9% |
| `phoneticKey` (`replacingOccurrences` via CF) | 8.2% | `keys` (grapheme + phonetic) | 2.1% |
| `lexicalMatches` (ICU) | 3.1% | `AliasMatcher::find_all` | 5.2% |
| `CleanupEngine.clean` | 19.9% | `cleanup::clean` | 8.3% |
| `Glossary.canonicalize` (alias derivation + regex compile per call) | 12.3% | `glossary::canonicalize` | 2.8% |
| `removeFillers` / `shouldSkipToken` (`userAliases` per token per term) | 5.8% / 4.9% | `remove_fillers` / `should_skip_token` | 4.5% / 4.4% |

Self time by category: Swift spends 33.2% in the Levenshtein loop, 16.6% in malloc/free, 9.9% in
ARC and uniqueness checks, 7.9% in generic-metadata and availability lookups, 10.7% in
Foundation/CF bridging and 7.6% in ICU. Rust spends 69.7% in the loop and 17.9% in malloc/free.
Both run the same O(windows x surfaces x profiles) scan, two `[Int]`/`Vec` rows allocated per
comparison. What separates them is the overhead Swift wraps around that scan.

Other stages:
- Engine build (cache miss), `VocabularyRepairEngine.init` 86.4%:
  - `aliasPattern` 30.1% (`NSRegularExpression.init` 26.3%).
  - `derivedAliases` 29.3%, of which `canonicalTokens` 18.7% compiles five regexes per canonical per call.
  - `phoneticKey` 18.8%.
  - `fromActiveTerms`' `Array(ordinaryWords)` copy and destroy, about 11%. With an empty glossary the stage takes 344 µs, against 6 µs for `swift-opt-repr`, which skips the copy.
- Compile (5,000 terms): 90.4% is the stable sort of `(offset, ProtectedTerm)` pairs. Each move copies a term and its optional `Date`; `Date` is a resilient Foundation type, so the copies go through runtime value witnesses. `recency(of:)` is also re-derived in every comparison (8.2%). The Rust port computes each key once.
- Empty glossary (`scale-0`): Swift's ~110 µs is all cleanup string passes. `removeFillers` and `shouldSkipToken` take 43%, `collapseAdjacentRepeats` 33%, and 25.6% of self time is Foundation `CharacterSet` work. That includes a `punctuationCharacters.union(.symbols)` rebuilt on every `strippedToken` call. Rust's ~20 µs is mostly grapheme iteration (unicode-segmentation) and allocation.

### The optimized Swift arms

`Optimized*.swift` (harness only) copies the production functions and keeps their algorithm: the same passes, iteration order, comparisons and tie-breaks. Parity shows them byte-identical on all 131,994 cases.

Representation fixes (both arms):
- Flat key tables, with the Levenshtein run over raw pointers using preallocated rows and wrapping `&+` (the cells are bounded).
- Byte-level phonetic replacements.
- ASCII inputs skip NFKD.
- Window substrings are made only for windows that are scored.
- POD sort keys, with the recency stored as `TimeInterval`.
- No `Array(ordinaryWords)` copy.

Memoization (`swift-opt` only):
- Fragile surfaces, skip-token surfaces (one `Set` lookup) and `canonicalize`'s alias expressions are built once per active-term list. The byte-exact cache check runs inside the timed unit.
- The constant regexes are compiled once per process.

`swift-opt-repr` keeps production's per-call work, the same work the Rust port does in the text stage.

After the fixes, `swift-opt` spends 79.6% of the text stage in the Levenshtein loop, with 8.4% ICU and 1.4% malloc. Its engine build is dominated by `NSRegularExpression.init` (44.7%), which the port replaces with a hand-written matcher.

### Dev smoke (not official: `scripts/b3-timing.sh 100 2`, load average 58.7 at the start, 14.3 at the end)

First 100 realistic rows, 2 measured passes, all arms in one process (`rust` is the separate
`text-bench` process). Columns are the per-row p50 in µs, then the total ratio (Σcand/Σbase) with its
95% BCa interval. Every arm agrees with every other on every row, and `equal_ref` is true for every
text row. A/A `swift@aa/swift` ranges from 0.945 to 1.026 except default7, at 1.129 [1.029, 1.250].

| text | active | swift | swift-opt-repr | swift-opt | rust-ffi | rust | (a) rust-ffi / swift | (b) swift-opt / swift | (c) rust-ffi / swift-opt | rust-ffi / swift-opt-repr |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |
| scale-0 | 0 | 109 | 109 | 116 | 22 | 16 | 0.167 [0.135, 0.182] | 0.997 [0.831, 1.144] | 0.168 [0.142, 0.181] | 0.182 [0.166, 0.191] |
| default7 | 7 | 1,795 | 1,177 | 403 | 372 | 329 | 0.292 [0.255, 0.342] | 0.319 [0.281, 0.400] | 0.914 [0.728, 1.035] | 0.512 [0.442, 0.597] |
| scale-10 | 10 | 1,356 | 790 | 394 | 352 | 360 | 0.299 [0.285, 0.318] | 0.321 [0.307, 0.337] | 0.931 [0.895, 0.980] | 0.592 [0.548, 0.639] |
| scale-50 | 50 | 4,968 | 3,876 | 1,351 | 1,440 | 1,415 | 0.367 [0.347, 0.386] | 0.340 [0.320, 0.360] | 1.081 [1.033, 1.108] | 0.575 [0.527, 0.621] |
| scale-100 | 98 | 9,678 | 7,047 | 2,523 | 3,079 | 3,694 | 0.415 [0.377, 0.461] | 0.325 [0.299, 0.349] | 1.275 [1.199, 1.382] | 0.647 [0.579, 0.719] |
| user-jargon | 100 | 6,716 | 4,582 | 2,064 | 2,548 | 3,049 | 0.428 [0.407, 0.446] | 0.360 [0.337, 0.385] | 1.190 [1.137, 1.284] | 0.748 [0.693, 0.817] |
| scale-1000 | 100 | 8,958 | 7,194 | 2,675 | 3,307 | 3,417 | 0.439 [0.418, 0.461] | 0.350 [0.334, 0.366] | 1.254 [1.229, 1.286] | 0.644 [0.596, 0.687] |
| scale-5000 | 100 | 12,168 | 9,729 | 4,470 | 5,324 | 4,903 | 0.491 [0.462, 0.520] | 0.404 [0.382, 0.422] | 1.215 [1.179, 1.268] | 0.718 [0.671, 0.764] |

| other stages (p50 µs) | swift | swift-opt | rust-ffi | rust-ffi / swift | rust-ffi / swift-opt |
| --- | ---: | ---: | ---: | --- | --- |
| compile default7 | 1.9 | 0.4 | 0.5 | 0.315 [0.279, 0.379] | 0.559 [0.159, 1.228] |
| compile user-jargon (180 terms) | 66.9 | 5.9 | 4.1 | 0.063 [0.060, 0.066] | 0.692 [0.660, 0.719] |
| compile scale-5000 | 5,199 | 205 | 157 | 0.029 [0.027, 0.030] | 0.744 [0.666, 0.776] |
| engine scale-0 | 344 | 1.7 | 1.6 | 0.004 [0.004, 0.006] | 0.787 [0.653, 0.914] |
| engine default7 | 1,088 | 441 | 81 | 0.072 [0.064, 0.080] | 0.189 [0.181, 0.212] |
| engine user-jargon | 7,944 | 4,533 | 609 | 0.077 [0.070, 0.085] | 0.118 [0.078, 0.141] |
| ordinary-word load (once per process) | 45,157 | — | 9,581 (`rust`) | — | — |

Reading (dev only; the official run decides):
- (a) What Rust buys at the same algorithm (`rust-ffi` vs `swift`): 2.0-3.4x on the text stage with 7-100 active terms, 6x with none. Compile is 3.2-43x faster (it grows with glossary size), and the engine build 12-15x (250x with an empty glossary, the array copy).
- (b) What optimized Swift buys (`swift-opt` vs `swift`): 2.5-3.1x on the text stage with any glossary. None of it comes from an empty glossary, where `swift-opt` runs production's cleanup passes unchanged. Compile is 1.8-27x faster, and the engine build 1.5-2.8x (170x with an empty glossary).
- (c) The residual gap (`rust-ffi` vs `swift-opt`):
  - With 50-100 active terms, `swift-opt` is 8-28% faster than the Rust port, which still allocates two rows per comparison.
  - With 7-10 terms the two are within about 10%.
  - With 0 terms Rust is 6x faster, about 90 µs per utterance, in cleanup string passes `swift-opt` does not change.
  - Rust stays ahead on compile (1.3-1.8x) and engine builds (5.3-8.5x; the gap is ICU regex compiles against the port's hand-written matcher).
  - At equal per-call work (`swift-opt-repr`), Rust's text stage is 1.3-5.5x faster.
- `rust` (separate process) and `rust-ffi` ran at different moments of a changing load. The cross-process ratio is confounded, which is why the in-process pairing is the primary comparison.

## Official timing (orchestrator; quiet machine; after `b3-parity.sh` passes)

```sh
bench/rust/voiceour-text/scripts/b3-timing.sh 300 10    # rows passes; 1310 = every realistic row (~4x longer)
```

For glossaries scale-0, scale-10, scale-50, scale-100, default7, user-jargon, scale-1000 and scale-5000, and stages
`text`, `compile` and `engine` (20 reps), it runs:
- one `swift-text-bench` process with all five in-process arms;
- `text-bench` (`rust`, `rust@aa`) on the same rows and order;
- `paired_stats.py` with the pairs above plus the A/A pairs.

It then times the ordinary-word load and the `rust-ffi` boundary. Rows, reports
(`report.<stage>.<glossary>.{md,json}`) and inputs go to `.build/rust-bench/b3/timing/` (override:
`B3_TIMING_OUT`). The dev smoke above took 178 s at `100 2`. [INFERENCE] `300 10` should take about
25-30 min, dominated by the text stage at 100 active terms.

## Not done (open)

- No official numbers yet: everything above is a dev smoke on a loaded machine.
- `swift-opt` does not touch the cleanup string passes: `CharacterSet` trimming, `components(separatedBy:)`, and Character-wise splits. These cost about 110 µs per utterance with an empty glossary and about 32% of `swift-opt` with default7. A constant `strippedToken` set is the obvious first fix; it was identified but not applied or measured.
- No `rust-opt` arm, so Rust's per-comparison row allocation is not fixed on the Rust side. (c) therefore compares an optimized Swift with the straight port.
