# Paired timing statistics (`paired_stats.py`)

`paired_stats.py` analyzes the timing rows the Rust proof-program harnesses write. It answers one question per arm
pair: on the same rows, is the candidate faster than the base, by how much, and do the two produce the same output?
It uses only the Python standard library (CPython 3.11 or newer) and is deterministic. Fixed inputs, flags and seed give
byte-identical JSON and Markdown.

```sh
python3 bench/rust/analysis/paired_stats.py RESULTS.jsonl [RESULTS2.jsonl ...] \
    (--pair BASE_ARM:CAND_ARM [--pair ...] | --all-vs BASE_ARM) \
    [--aggregate median|min] [--include-warmup] [--seed 20261016] [--bootstrap 10000] \
    [--json OUT.json] [--md OUT.md] [--stage-profile [--stage-parts mel,encode,tail]] [--stage-tolerance 0.01] \
    [--check]

python3 -m unittest bench/rust/analysis/test_paired_stats.py
```

- `--pair BASE:CAND` compares CAND against BASE. Repeat it for more pairs. Arm names may contain `:`. The tool uses
  the one split where both sides are arms in the inputs, and rejects a spec that splits two ways.
- `--all-vs BASE` compares every arm except BASE and the `@aa` arms against BASE. You cannot combine it with `--pair`.
- `--stage-profile` analyzes `stage_profile` rows. You can use it alone or together with a timing analysis.
- `--stage-parts A,B,...` (with `--stage-profile`) names the stages that are inside `full`. See
  [Stage profile](#stage-profile-stage_profilegroupsg).
- `--check` is the strict gate used by `bench/rust/run_official.sh`. On top of the integrity checks every run gets,
  it refuses runtime errors and a `run_end` that reports failed calls. It needs no `--pair`, `--all-vs` or
  `--stage-profile`; alone it prints one integrity line per run.
- `--aggregate` sets how each (arm, row) is reduced over its passes. The default is `median`.
- `--include-warmup` keeps pass 0. By default pass 0 is warmup and is excluded.
- `--seed` and `--bootstrap` set the bootstrap seed and the number of resamples B. The defaults are 20261016 and
  10000. Below 1000 resamples the tool warns.
- `--json` writes the full report. `--md` writes the Markdown. Without `--md`, Markdown goes to stdout.
  Missing parent directories are created.
- Every warning also goes to stderr. The exit code is 0 on success and 2 on bad input or bad flags.

Large evidence (raw rows, reports) belongs under `.build/rust-bench/`. Never put it under `benchmarks/data/` or
`research/`.

## Inputs

The input is JSONL with one JSON object per line. Blank lines are skipped. A line that is not JSON aborts the run and
reports `file:line`. Rows of any other `type` are counted and reported in the `ignored_rows` warning.

- `run_meta`: `{"type":"run_meta","bet","harness","git_sha","started_at","host":{"chip","os","os_build","power",
  "load_avg","cpu_threads","perf_cores","eff_cores","memory_bytes"},"arms","passes","order","corpus","notes"}`. The
  tool copies it verbatim into the report. Its `corpus` and `bet` values apply to the timing rows that follow it in
  the same file. A new `run_meta` starts a new run inside the file. These fields also have a meaning for the
  [run integrity](#run-integrity) checks: `arms` and `passes` (the grid a run declares), `completion_required`
  (the run must end with a `run_end` line), `host.power` and `executable_sha256` (provenance).
- `run_end`: `{"type":"run_end","expected_timing_rows","written_timing_rows","failures"}`, the last line of a run
  whose harness can tell that it finished. `timing_rows` and `failed_calls` are accepted for `written_timing_rows`
  and `failures`. An optional `status` of `aborted`, `invalid`, `failed`, `error`, `incomplete` or `cancelled`
  refuses the run.
- `timing`: `{"type":"timing","bet","arm","row_id","pass","seq","elapsed_us","output_sha256","equal_ref","audio_s",
  "work","err"}`.
  - These fields are required, and a bad value aborts the run:
    - `arm` is a non-empty string.
    - `row_id` is a non-empty string or an integer. It is compared as a string.
    - `pass` is a non-negative integer.
    - `output_sha256` is a string or null.
    - `equal_ref` is true, false or null.
    - `err` is an object or null.
  - If `elapsed_us` is missing, non-numeric, non-finite or ≤ 0, the sample is excluded. It is counted in
    `timing.invalid_samples` (with a `reason`: `missing`, `non_numeric`, `non_finite`, `zero` or `negative`) and the
    `invalid_samples` warning. An exact 0 is a timer read below its resolution. It stays excluded and is reported
    as `zero_elapsed`; the tool never substitutes an epsilon.
  - A row whose `work.error` is truthy, or whose `work.non_finite` is greater than 0, is a runtime error. It is
    excluded whatever `elapsed_us` says, counted under `timing.runtime_errors`, and never counted as zero time.
    See [Runtime errors](#runtime-errors).
  - If `audio_s` is missing or ≤ 0, the row has no audio duration. When samples of one row disagree by more than
    1e-6 relative, the tool uses the first value in input order and warns `audio_s_inconsistent`.
  - A missing `seq` only removes the sample from the drift analysis (`seq_missing` warning).
  - `work` is not analyzed beyond `error` and `non_finite`.
- `stage_profile`: `{"type":"stage_profile","row_id","pass","audio_s","stages_us":{...},"counts":{...}}`.
  - Optional fields:
    - `arm`: rows are grouped by it. Rows without an arm go to the group `all`.
    - `corpus`: overrides the `run_meta` value.
  - `stages_us` must be a non-empty object of finite numbers ≥ 0. The stage name `(unattributed)` is reserved.
  - Non-numeric `counts` values are ignored.

Row identity:

- Rows are matched by `row_id`.
- If the inputs mix corpora (from `run_meta.corpus` or a row's own `corpus` field), ids from different corpora could
  collide. The key then becomes `<corpus>/<row_id>`, with `?` for an unknown corpus. `timing.row_identity` reports
  which key was used.
- If one arm name appears under two different `bet` values, the run aborts. Analyze one bet per invocation.
- A repeated (arm, row_id, pass) key is refused when the run's `run_meta` declares `arms` and `passes`. Without a
  declared grid, all repeats are aggregated and the tool warns `duplicate_samples`. The same key in two input files
  is refused in every case, because it would pool replicates of one arm taken in different processes.

## Run integrity

The tool checks every run before it computes a statistic and refuses an incomplete one with exit code 2. A run is
the rows from one `run_meta` line to the next (or to the end of the file).

**Declared grid.** When `run_meta` has a list `arms` and an integer `passes`, every arm must write every `row_id`
once for each pass `0..passes`. The row ids are the ones that appear anywhere in the file. The tool refuses:

- a repeated (arm, row_id, pass) key;
- a declared pass index that is missing for some row and arm (an interrupted run);
- an arm that is declared but never written, or written but not declared;
- a pass index above `passes`.

A stage-profile run (stage rows, no timing rows) is checked the same way, with the `arm` field (or `all`) as the
group. Timing rows that carry a runtime error or a zero elapsed time still count as written.

**Completion footer.** A harness that sets `completion_required: true` in `run_meta` must end the run with a
`run_end` line. The tool refuses a missing footer, more than one footer, rows after it, a `status` of `aborted`
or the like, a missing `expected_timing_rows`, `written_timing_rows` or `failures`, a `written_timing_rows` that
differs from the rows in the file, an `expected_timing_rows` that differs from `written_timing_rows`, and an
`expected_timing_rows` that differs from arms × rows × (passes + 1). A footer without the flag is checked the same
way. For a stage-profile file the stage rows count as the timing rows. Failed calls in the footer raise the
`run_reported_failures` warning, and `--check` refuses them.

**Legacy runs.** A run without a footer cannot prove that a whole row, or a whole arm, was not left out, because
the grid is checked only against the rows and arms that appear. When its grid is complete, the tool analyzes it and
warns `incomplete_provenance`; the integrity table shows `grid_only`. A file without `run_meta`, or one that
declares no `arms` or `passes`, warns the same way and is not checked at all. The B1, B2, B3 and B6 data files of
runs `20261016-run2` and `20261017-resumed` were written before the footer existed and have complete declared grids
(counted separately), so they are expected to pass with this warning. The interrupted B4 file of `20261016-run2`
(2464 of 3072 cells) is refused.

**Provenance warnings.** Each `run_meta` is checked for `host.power`. A value that is not AC (or is missing) raises
`non_ac_power`: a battery run can be power-capped, so its absolute times do not compare with AC runs. Each
`run_meta` is also checked for `executable_sha256`; without it the tool raises `no_executable_fingerprint`, since
nothing then identifies the binary that wrote the rows.

## Runtime errors

A timing row with `work.error` or `work.non_finite` > 0 failed at run time. It is not a sample. The tool counts it
under `timing.runtime_errors` (per arm: samples, rows, dropped rows, kinds, the first message) and warns
`runtime_errors`. A row with such a sample in a timed pass is dropped for that arm: its other passes would be the
survivors of a failing implementation, and a pair would otherwise compare only the rows where the candidate happened
to run. An arm whose every row failed stays in the report with 0 rows, and its pairs have no common rows. An error in
warmup pass 0 alone counts but keeps the row, unless `--include-warmup` is given.

## Notation and shared definitions

- Timed samples are passes ≥ 1. With `--include-warmup`, every pass is timed.
- `x(arm, row)` is the per-row aggregate over the timed samples. With `median`, it is `Q(0.5)`; with `min`, it is the
  smallest sample.
- `Q(p)` is the type-7 quantile (linear interpolation between closest ranks, numpy's default). For an ascending sample
  `y_0 … y_{m−1}`, let `h = (m − 1)·p` and `j = ⌊h⌋`. Then `Q(p) = y_j + (h − j)·(y_{min(j+1, m−1)} − y_j)`. p50,
  p90, p95 and p99 are `Q(0.50)`, `Q(0.90)`, `Q(0.95)` and `Q(0.99)`. The median is `Q(0.5)`.
- Rows are ordered "naturally": digit runs compare as numbers, so `row2` sorts before `row10`. This order fixes the
  bootstrap's row positions and every listed row id. Lists of row ids are capped at 20 and carry the full `count`.
- Sums use `math.fsum`, which is correctly rounded and independent of order.
- `Φ(x) = ½·erfc(−x/√2)`. `Φ⁻¹` is `statistics.NormalDist().inv_cdf`. `z_q = Φ⁻¹(q)`. α = 0.05.

For a pair (base B, candidate C), only the rows present in both arms (`i = 1..n`) are compared. Rows present in only
one arm are listed under `dropped_rows` and trigger the `dropped_rows` warning. For each row:

- `b_i = x(B, i)` and `c_i = x(C, i)`. Both are > 0.
- `a_i` is the row's audio seconds, when known.
- `r_i = c_i / b_i`
- `d_i = ln r_i`
- `s_i = b_i − c_i`. A positive saving means the candidate is faster.

## Per-arm statistics (`timing.arms[arm]`)

`arms[arm]` covers all of the arm's rows. Each pair also carries `base_stats` and `cand_stats`, which use the same
fields over the pair's common rows.

- `rows` is the number of rows with at least one timed sample. `samples` is the number of timed samples. `passes` lists
  the timed pass indices.
- `elapsed_us` has `n`, `sum`, `mean = sum/n`, `p50`, `p90`, `p95`, `p99`, `min` and `max` of `x(arm, ·)`.
- `audio_rows` is the number of rows with a known `a`. `audio_s_total` is `Σa` over those rows.
- `us_per_audio_s` gives the same distribution fields for `x/a` over those rows.
- `total_us_per_audio_s = Σx / Σa` over those rows. This is the time-weighted rate.
- `equivalence`: see [Equivalence](#equivalence).

## Pair statistics (`timing.pairs[k].speed`)

| field | definition |
|---|---|
| `base_total_us`, `cand_total_us` | `Σb_i`, `Σc_i` |
| `total_ratio.point` | `R = Σc_i / Σb_i`. This is the time-weighted speed ratio and the headline number. |
| `geomean_ratio.point` | `G = exp(d̄)` with `d̄ = (1/n)·Σd_i` (`mean_log_ratio`) |
| `median_ratio` | `Q(0.5)` of `r_i` |
| `rows_faster`, `rows_slower`, `rows_tied` | `#{c_i < b_i}`, `#{c_i > b_i}`, `#{c_i = b_i}` |
| `fraction_faster` | `rows_faster / n` |
| `saving_us.mean` | `s̄ = (Σb_i − Σc_i) / n` |
| `saving_us.p50` | `Q(0.5)` of `s_i` |
| `saving_us.total` | `Σb_i − Σc_i` |
| `saving_us_per_audio_s.mean`, `.p50` | mean and `Q(0.5)` of `s_i / a_i` over the rows with a known `a_i` (`rows`) |
| `saving_us_per_audio_s.total` | `Σs_i / Σa_i` over those rows. This is the time-weighted saving per audio second. |
| `wilcoxon` | Wilcoxon signed-rank test on `d_i`, defined below |
| `sign_test` | exact binomial sign test, defined below |

The first ratio statistic (`total_ratio`) answers "how much less total time". The second (`geomean_ratio`) answers
"how much faster is a typical row". A ratio below 1 means the candidate is faster.

### Bootstrap confidence intervals

Three statistics carry a 95% interval: `total_ratio.ci95`, `geomean_ratio.ci95` and `saving_us.ci95_mean`. The
geomean interval is computed for `d̄` and then exponentiated.

**Resampling.** Each pair gets its own seed, so adding or removing pairs does not change a pair's numbers. The seed is
the first 8 bytes, read big-endian, of `SHA-256("paired_stats\0{seed}\0{base}\0{cand}")`. A
`random.Random(pair_seed)` generator then produces B resamples. Each resample draws n row positions
`j = ⌊U·n⌋`, where `U` is the next value of `.random()`. Rows are drawn with replacement and keep their base and
candidate values together. For each resample k:

- `R*_k = Σ_j c_j / Σ_j b_j`
- `d̄*_k = (1/n)·Σ_j d_j`
- `s̄*_k = (Σ_j b_j − Σ_j c_j) / n`

**Percentile interval.** `[Q*(α/2), Q*(1 − α/2)]`, where `Q*` is the type-7 quantile of the B replicates.

**BCa interval** (Efron's bias-corrected and accelerated interval). For a statistic with point estimate `θ̂` and
replicates `θ*`:

- Bias correction: `z0 = Φ⁻¹(p0)`, where `p0 = (#{θ* < θ̂} + ½·#{θ* = θ̂}) / B`, clipped to `[½/B, 1 − ½/B]`.
- Jackknife values `θ_(i)`, each leaving out row i:
  - `R_(i) = (Σc − c_i) / (Σb − b_i)`
  - `d̄_(i) = (Σd − d_i) / (n − 1)`
  - `s̄_(i) = ((Σb − b_i) − (Σc − c_i)) / (n − 1)`
- Acceleration: `a = Σ(θ̄ − θ_(i))³ / (6·[Σ(θ̄ − θ_(i))²]^{3/2})` with `θ̄ = mean of θ_(i)`. It is 0 when every
  `θ_(i)` is equal.
- Adjusted levels: `α₁ = Φ(z0 + (z0 + z_{α/2}) / (1 − a·(z0 + z_{α/2})))` and
  `α₂ = Φ(z0 + (z0 + z_{1−α/2}) / (1 − a·(z0 + z_{1−α/2})))`.
- Interval: `[Q*(α₁), Q*(α₂)]`.

BCa is undefined when n < 2 or when either denominator is ≤ 0. Because |a| ≤ 1/6, the denominator can only reach 0
when |z0| ≳ 4. That needs B ≳ 18 000 and a point estimate outside almost every replicate. The reason is reported in
`bca_reason`.

**Fields of each interval.**

- `percentile` and `bca` (null when undefined).
- `method`: `bca` when BCa is defined, otherwise `percentile`. `low` and `high` hold the bounds of that method.
- `null` (1 for ratios, 0 for savings) and `excludes_null = not (low ≤ null ≤ high)`.
- `bca_z0`, `bca_acceleration`, `bca_adjusted_probabilities = [α₁, α₂]`, `bca_reason`.
- `resamples`.
- `bootstrap_se`, the sample standard deviation of the replicates. It is on the log scale for the geomean
  (`statistic_scale: "log"`).

With n = 1 every interval is null. With n < 10 the tool warns `small_n`.

### Wilcoxon signed-rank test (`speed.wilcoxon`)

The test runs on `d_i = ln(c_i / b_i)`, so it does not depend on the time scale. It is two-sided. Zeros are handled
with Pratt's method:

- Rank all n values of `|d_i|`, zeros included. Tied values get their mid-rank.
- Drop the zeros. `W⁺ = Σ ranks of d_i > 0` and `W⁻ = Σ ranks of d_i < 0`.
- `n_zero` counts the zeros. `n_nonzero = m`.

**Exact, for n ≤ 25** (`method: "exact"`). Under H0, each nonzero `d_i` is positive or negative with probability ½,
independently. That gives 2^m equally likely sign patterns over the observed mid-ranks. The tool counts them exactly
as integer subset sums of the doubled ranks (mid-ranks are multiples of ½). Then
`p = min(1, 2·min(P(W ≤ W⁺_obs), P(W ≥ W⁺_obs)))`. This conditional distribution handles ties and zeros exactly.

**Normal approximation, for n > 25** (`method: "normal"`). It uses Cureton's zero correction and the tie correction,
without a continuity correction:

- `μ = [n(n+1) − n₀(n₀+1)] / 4`
- `σ² = [n(n+1)(2n+1) − n₀(n₀+1)(2n₀+1)] / 24 − Σ_t (t³ − t) / 48`. The sum runs over tie groups of size t among
  the nonzero `|d_i|`.
- `z = (W⁺ − μ) / σ` and `p = erfc(|z| / √2)`.

The JSON also reports `mean` and `variance` for this method. When m = 0, the method is `degenerate` and p = 1. In a
development cross-check against scipy 1.18.1, the normal branch matched
`scipy.stats.wilcoxon(zero_method="pratt", correction=False, method="asymptotic")` to within 3e-15 relative, and the
exact branch equalled scipy's exact and full-permutation p-values.

### Sign test (`speed.sign_test`)

The test ignores tied rows. With `k⁺ = rows_faster`, `k⁻ = rows_slower`, `m = k⁺ + k⁻` and `k = min(k⁺, k⁻)`:

`p = min(1, 2·Σ_{i=0..k} C(m, i) / 2^m)`

The sum is exact integer arithmetic, followed by one correctly rounded division. p = 1 when m = 0.

## A/A noise floor (`timing.pairs[k].noise_floor`)

An arm named `X@aa` is an A/A replicate of `X`. When both arms exist, the tool appends the pair `X vs X@aa` (with
`kind: "aa"`) after the requested pairs. A pair you request yourself is not repeated.

For each comparison pair (base B, candidate C), the reference pairs are `B vs B@aa` and `C vs C@aa`, where they
exist. If neither exists but other A/A pairs do, all of them are used, and the pair is marked `proxy: true`.

For each reference and each metric (`total_ratio` and `geomean_ratio`), let the primary intervals be `[l₁, u₁]` and
`[l₂, u₂]`. They overlap iff `l₁ ≤ u₂ and l₂ ≤ u₁`. `within_noise_floor` is true when any check overlaps. The pair is
then flagged with the `within_noise_floor` warning and `WITHIN noise` in the Markdown. This means the measured
difference cannot be told apart from the difference between two copies of the same code.

Two other warnings come from this step:

- `aa_bias`: an A/A total-ratio interval excludes 1. Identical code measured differently, which means order,
  position or thermal bias is present.
- `no_aa`: there is no A/A arm at all.

`noise_floor` is null for A/A pairs and when no A/A pair exists.

## Equivalence

Equivalence uses every pass of a row, warmup included. It does not depend on `--include-warmup` or `--aggregate`.
For a row that has timed samples, let `H(arm, row)` be the set of distinct non-null `output_sha256` values.

Per pair (`pairs[k].equivalence`), over the common rows:

- `hash_missing`: rows where either arm's `H` is empty. These rows are not compared. The tool warns `hash_missing`
  when other rows were compared.
- `compared = rows − hash_missing.count`.
- `identical`: rows with `|H(B)| = 1` and `H(B) = H(C)`. `identical_rate = identical / compared`.
- `mismatched`: compared rows that are not identical. This includes rows that are nondeterministic in either arm. The
  first 20 row ids are listed, with the full count. For an A/A pair, any mismatch triggers `aa_output_mismatch`.
- `base` and `cand`: the per-arm fields below, restricted to the common rows.

Per arm (`arms[arm].equivalence`), over all of the arm's rows:

- `hash_rows` is the number of rows with a non-empty `H`. `nondeterministic_rows` lists rows with `|H| > 1`
  (`nondeterministic_output` warning).
- `equal_ref`: a row is false if any non-null sample is false, true if every non-null sample is true, and null if it
  has none. The arm reports `true`, `false`, `null`, `rate = true / (true + false)` and `false_rows`.
- `err.max_abs` and `err.rel_l2`:
  - `max` is the maximum over every finite sample value. `row_id` is the first row, in natural order, that reaches it.
  - `samples` counts the samples that report the field.
  - `nonfinite_samples` counts NaN or ±inf values (`err_nonfinite` warning).
  - The whole entry is null when no sample reports the field.

## Drift (`timing.drift`)

Drift is computed for each input file and arm, over the timed samples that have a numeric `seq`:

- `rho = Spearman(seq, elapsed_us)`. Spearman's rho is the Pearson correlation of the mid-ranks.
- `rho_row_normalized = Spearman(seq, elapsed_us / x(arm, row))`. Dividing by the row's aggregate removes row
  content, so this still detects time drift when every pass runs the rows in the same order (for example, sorted by
  length).
- `warn` is set when either |rho| > 0.3, and the tool warns `drift`. A rho is null when fewer than 3 samples exist
  or one series is constant.

## Stage profile (`stage_profile.groups[g]`)

Only timed passes are used. For each sample with a `full` stage:

- `parts = Σ(stages except full)`
- `coverage = parts / full`, when `full > 0`
- `unattributed = full − parts`

For each row, every stage and `(unattributed)` is reduced over passes with `--aggregate`. Per stage, over the rows
that report it:

| field | definition |
|---|---|
| `rows` | rows reporting the stage |
| `p50_us`, `p95_us`, `mean_us` | `Q(0.5)`, `Q(0.95)` and mean of the per-row stage µs |
| `p50_ms`, `mean_ms`, `total_ms` | `p50_us/1000`, `mean_us/1000` and `Σ/1000` |
| `share_rows` | rows that also have `full > 0` |
| `share_of_full_p50` | `Q(0.5)` of `stage_r / full_r` over those rows |
| `share_of_total_full` | `Σ_r stage_r / Σ_r full_r` over those rows. This time-weighted share is the Amdahl fraction. |
| `us_per_audio_s_p50` | `Q(0.5)` of `stage_r / audio_s_r` over the rows with audio |

The `(unattributed)` row is the glue time between stages. It is negative where stages overlap.

`consistency` checks each sample's stages against `full`:

- `coverage` reports min, p50 and max.
- `over_full`: samples with `coverage > 1 + tolerance` (`--stage-tolerance`, default 0.01). The first 20 are listed,
  and the tool warns `stage_overcount`.
- `samples_missing_full` counts samples without `full` (`stage_missing_full` warning, or `stage_no_full` when no
  sample has it). `samples_zero_full` counts samples with `full = 0`.
- `consistent` is true only when `full` exists, no sample exceeds the tolerance, and none lacks `full`.

The sum check assumes stages are disjoint, so a producer should not nest stages. With `--aggregate min`, per-stage
minima can come from different passes, so the shares need not add up to 1. `counts` reports `rows`, `mean`, `p50`,
`min`, `max` and `total` of the per-row median of each count key.

**Scope of `full`.** Without `--stage-parts` every stage except `full` is treated as a part of it. That is wrong
when a producer measures some stages outside `full`. The B0 ledger (`voiceour-bench stage-profile`) times `wav_read`,
`assemble`, `cleanup` and `repair` outside `full`; only `mel`, `encode` and `tail` are native counters inside it.
Summing all of them overcounts `full` and the tool warns `stage_overcount`. With `--stage-parts mel,encode,tail`:

- every selected part must exist in each group (an unknown name, `full`, `(unattributed)`, a repeat or an empty
  name is an error), and a sample that lacks a selected part raises `stage_missing_part`;
- `parts` is the sum of the selected parts only, so `coverage = parts / full` and `(unattributed) = full − parts`;
- every other stage is listed under `outside_full` (`scope: "outside_full"`) with its own times, and no share of
  `full`. It is never added to or subtracted from `full`, and cleanup or repair time is never netted out of ASR.

`stage_profile.groups[g].scope` records `mode` (`selected_parts` or `all_non_full`), the `parts` and the
`outside_full` names; each stage entry carries a `scope` of `part`, `unattributed`, `full` or `outside_full`.

## Output

The JSON report contains:

- `tool`, `schema_version` and `settings`. `settings` holds every flag value and every fixed constant: α,
  quantile method, the n ≤ 25 exact threshold, the Pratt zero method, the 0.3 drift threshold, the 20-id list limit,
  the stage tolerance, `stage_parts` and `check`.
- `inputs`: path, SHA-256, non-empty line count, counts by row type, ignored types, the verbatim `run_meta` objects
  and the verbatim `run_end` objects.
- `warnings`: a list of `{code, message}` objects.
- `integrity`: one entry per run: `path`, `run_meta_line`, `completion_required`, row counts, `grid` (groups, rows,
  passes, `expected_cells`, `written_keys`, missing and duplicate counts), `footer` (`valid`, `invalid` or
  `missing`), `runtime_error_rows` and `status` (`verified`, `footer_only`, `grid_only` or `unchecked`).
- `timing`: `row_identity`, `invalid_samples`, `runtime_errors`, `arms`, `pairs` and `drift`. Each pair contains
  `label`, `base`, `cand`, `kind`, `n`, `dropped_rows`, `noise_floor`, `seed`, `speed`, `base_stats`, `cand_stats`
  and `equivalence`. A pair with no common rows has an `error` field instead of statistics. This key is null unless
  `--pair` or `--all-vs` is given.
- `stage_profile`: `row_identity` and `groups`. This key is null unless `--stage-profile` is given.

Non-finite values are written as null, so the file is strict JSON.

The Markdown report has these sections: Inputs (with run_meta summaries), Run integrity, Warnings, Arms, Runtime
errors, Pairs: speed (with the A/A column), Pairs: tests and savings, Equivalence, Arms: equivalence, Drift, Dropped
rows and Stage profile. Every number in it comes from the JSON report, and `render_markdown(json.load(...))`
reproduces it byte for byte.

Determinism comes from these choices:

- each pair has its own seed
- the only random draws are MT19937's `random()`, whose sequence Python guarantees for a given seed
- sums are correctly rounded
- `Φ` uses `math.erfc` (`statistics.NormalDist.cdf` changed between CPython releases)

The same smoke input produced byte-identical JSON on CPython 3.11, 3.12 and 3.15 on macOS arm64.

## Reading the result

- The tool treats rows as exchangeable sampling units. Pass-to-pass noise reaches the intervals only through the
  per-row aggregate. If one row dominates `Σb`, the total ratio follows that row. Compare it with the geomean in that
  case.
- A pair's claim is credible when all of these hold:
  - its primary interval excludes 1
  - it is clear of the A/A noise floor
  - drift is ok
  - equivalence is what the bet requires (identical hashes, or bounded `err`)
- The tool does not correct for multiple comparisons across pairs.
- The absolute saving (`saving_us`) and its rate per audio second are the numbers to weigh against the real
  stop→delivery latency ledger.

## What the numbers do not say

- **Rows, not a population.** Every interval is conditional on the rows in the file and on that one run: the
  machine, its load, its power state, the build and the order of arms. It does not describe other audio, other
  machines or other days. A corpus is a sample of itself.
- **A/A is a floor for position and order bias, not for everything.** The A/A pair runs one implementation twice in
  one process and one schedule. A carryover effect that depends on the kind of work the predecessor did (CPU- or
  GPU-bound: clocks, caches, thermal and memory state, which compute unit a heterogeneous chip uses) hits both
  replicates alike, because both are the same kind of work. The A/A ratio then stays near 1, while a candidate of
  another kind, preceded by the same arms, is affected differently. A/A cannot detect that, so a ratio clear of the
  A/A interval can still carry it. Arms that hold large weights side by side (for example several encoders, about
  8.5 GiB together) can also change each other's memory behavior: run them in separate processes, each with its own
  baseline and A/A, and never pool baseline replicates across processes.
- **No arithmetic on the saving.** A saving is a measurement of one stage on isolated, offline calls. Multiplying
  it, or its ratio, into the stop-to-delivery latency of a real session assumes that stages do not overlap, queue
  or share resources, which the stage ledger does not show. Report the saving in µs and as a share of the ledger,
  not as a predicted end-to-end gain.
- **A ratio does not name its cause.** A C arm and a Rust arm that differ in speed differ in an implementation, an
  algorithm, a compiler and a memory layout together. The tool does not separate the language from them, so do not
  write that Rust, or C, caused a gain. Only a control that changes one factor at a time can support that.
- **No multiple-comparison correction**, and no claim of a global ranking from a handful of pairs.

## Official runner (`bench/rust/run_official.sh`)

The runner sequences the official runs; it does not change what is measured. It stops on a failed check and keeps
the files it has written:

- It makes `RUST_BENCH_OUT` absolute once, and it never overwrites an output: a new run needs a new directory.
- The machine must be on AC power before and after every measurement (`pmset` and the host log).
- Each measured file goes through `paired_stats.py --check` at once. An incomplete grid, a missing completion
  footer, a runtime error or a failed call stops the run. Analysis then refuses such a file again, so a partial
  file is never summarized.
- B4 runs one Rust candidate per process. All six candidates (`candle:f16w+fused`, `candle:f16+fused`, `mlx:f32`,
  `mlx:f32-mm16`, `mlx:f16`, `mlx:compiled-f16`) ran in one process before, with about 8.5 GiB of weights resident,
  risking memory pressure on a 24 GB laptop and letting cache and allocator state carry over. Now each
  process loads only its own library and measures it against its own native `ggml-metal` and `ggml-metal@aa` arms,
  on every corpus, with the same passes. The files are `b4.<engine>-<arm>.<corpus>.jsonl`, with `:` and `+` in
  the arm replaced by `-` (for example `b4.candle-f16w-fused.general96.jsonl`). The analysis step runs once per
  file, `--all-vs ggml-metal`, so each candidate is compared with the baseline and A/A replicate of its own process.
  Pooling files is refused (the same arm and row in two files).
- The candle candidates need `bench/rust/encoder-candle/vendor/`: run
  `bench/rust/encoder-candle/patches/vendor-candle-metal-kernels.sh` once on a clean checkout, then
  `cargo build --release` in `bench/rust/encoder-candle`. The runner checks that the vendored directory exists
  and that the candle library is newer than it.
- The ledger analysis uses `--stage-profile --stage-parts mel,encode,tail`, because `wav_read`, `assemble`,
  `cleanup` and `repair` run outside `full`.
