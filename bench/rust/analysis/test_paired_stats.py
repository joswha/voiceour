"""Unit tests for paired_stats.py: `python3 -m unittest bench/rust/analysis/test_paired_stats.py`."""

from __future__ import annotations

import contextlib
import io
import json
import math
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import paired_stats as ps  # noqa: E402

BOOTSTRAP = 2000
PASS_NOISE = (0.97, 1.0, 1.03)


def timing_row(
    arm, row_id, pass_index, seq, elapsed_us, *, sha="out", equal_ref=True, audio_s=1.0, err=None, bet="B1", work=None
):
    return {
        "type": "timing",
        "bet": bet,
        "arm": arm,
        "row_id": row_id,
        "pass": pass_index,
        "seq": seq,
        "elapsed_us": elapsed_us,
        "output_sha256": sha,
        "equal_ref": equal_ref,
        "audio_s": audio_s,
        "work": {} if work is None else work,
        "err": err,
    }


def run_meta(arms, *, corpus="synthetic", bet="B1", passes=3, power="ac", **extra):
    meta = {
        "type": "run_meta",
        "bet": bet,
        "harness": "unit-test",
        "git_sha": "0" * 40,
        "started_at": "2026-10-16T00:00:00Z",
        "host": {"chip": "test", "os": "test", "power": power, "load_avg": [0.1, 0.1, 0.1]},
        "arms": arms,
        "passes": passes,
        "order": "interleaved",
        "corpus": corpus,
        "notes": "synthetic",
    }
    meta.update(extra)
    return meta


def run_end(expected, *, written=None, failures=0, **extra):
    footer = {
        "type": "run_end",
        "expected_timing_rows": expected,
        "written_timing_rows": expected if written is None else written,
        "failures": failures,
    }
    footer.update(extra)
    return footer


GRID_ROWS = tuple(f"q{index}" for index in range(12))


def grid_rows(arms=("base", "cand"), row_ids=GRID_ROWS, passes=3, *, meta=True, **meta_extra):
    """A complete declared grid: every arm x row x pass 0..passes once. `cand` runs in 0.8 of `base`'s time."""
    rows = [run_meta(list(arms), passes=passes, **meta_extra)] if meta else []
    seq = 0
    for pass_index in range(passes + 1):
        for row_id in row_ids:
            for arm in arms:
                level = 1000.0 + 10.0 * int(row_id[1:])
                rows.append(timing_row(arm, row_id, pass_index, seq, level * (0.8 if arm == "cand" else 1.0)))
                seq += 1
    return rows


def mark_failed(rows, arm, row_ids, *, passes=None, work=None, elapsed=None):
    """Turn the matching timing rows into runtime failures, as the Swift harness writes them."""
    for row in rows:
        if row["type"] == "timing" and row["arm"] == arm and row["row_id"] in row_ids:
            if passes is None or row["pass"] in passes:
                row["work"] = work or {"error": "Metal error Error while loading library: BlockMMA"}
                row["elapsed_us"] = elapsed


def paired_levels(pairs=60, seed=11):
    """Row levels in µs; rows r{2k} and r{2k+1} share a level so symmetric factors cancel exactly in the totals."""
    rng = random.Random(seed)
    levels = {}
    for index in range(pairs):
        level = 3000.0 + 7000.0 * rng.random()
        levels[f"r{2 * index}"] = level
        levels[f"r{2 * index + 1}"] = level
    return levels


def alternating(levels, even, odd):
    return {row: even if int(row[1:]) % 2 == 0 else odd for row in levels}


def interleaved_rows(levels, factors, *, passes=3, seed=5, warmup_factor=2.0, meta=True):
    """Timing rows over passes 0..passes: every timed pass multiplies the row level by one of PASS_NOISE (a
    permutation per arm and row, so the median over timed passes is exactly level * factor), warmup pass 0 by
    warmup_factor. Row order is shuffled per pass and arm order rotates per row."""
    assert passes == len(PASS_NOISE)
    rng = random.Random(seed)
    arms = list(factors)
    noise = {}
    for arm in arms:
        for row in levels:
            permutation = list(PASS_NOISE)
            rng.shuffle(permutation)
            noise[(arm, row)] = permutation
    rows = [run_meta(arms, passes=passes)] if meta else []
    seq = 0
    for pass_index in range(passes + 1):
        order = list(levels)
        rng.shuffle(order)
        for position, row in enumerate(order):
            shift = position % len(arms)
            for arm in arms[shift:] + arms[:shift]:
                multiplier = warmup_factor if pass_index == 0 else noise[(arm, row)][pass_index - 1]
                elapsed = levels[row] * factors[arm][row] * multiplier
                rows.append(timing_row(arm, row, pass_index, seq, elapsed, audio_s=levels[row] / 1000.0))
                seq += 1
    return rows


class TempDirTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write_jsonl(self, name, rows):
        path = self.tmp / name
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return str(path)


def pair_by_label(report, label):
    return next(pair for pair in report["timing"]["pairs"] if pair["label"] == label)


def warning_codes(report):
    return {item["code"] for item in report["warnings"]}


class SpeedupAndNoiseFloorTests(TempDirTestCase):
    @classmethod
    def setUpClass(cls):
        levels = paired_levels()
        cls.levels = levels
        cls.factors = {
            "ggml": dict.fromkeys(levels, 1.0),
            "ggml@aa": alternating(levels, 0.97, 1.03),
            "rust": alternating(levels, 0.8 * 0.9, 0.8 * 1.1),
            "tiny": alternating(levels, 0.999 * 0.97, 0.999 * 1.03),
        }

    def report(self, **kwargs):
        path = self.write_jsonl("speedup.jsonl", interleaved_rows(self.levels, self.factors))
        options = {"pairs": ["ggml:rust", "ggml:tiny"], "bootstrap": BOOTSTRAP}
        options.update(kwargs)
        return ps.analyze([path], **options)

    def test_known_twenty_percent_speedup(self):
        report = self.report()
        pair = pair_by_label(report, "ggml vs rust")
        speed = pair["speed"]
        self.assertEqual(pair["n"], 120)
        self.assertAlmostEqual(speed["total_ratio"]["point"], 0.8, places=12)
        interval = speed["total_ratio"]["ci95"]
        for low, high in (interval["bca"], interval["percentile"]):
            self.assertLess(low, 0.8)
            self.assertGreater(high, 0.8)
            self.assertLess(high, 1.0)
        self.assertEqual(interval["method"], "bca")
        self.assertTrue(interval["excludes_null"])
        expected_geomean = 0.8 * math.sqrt(0.9 * 1.1)
        self.assertAlmostEqual(speed["geomean_ratio"]["point"], expected_geomean, places=12)
        geomean = speed["geomean_ratio"]["ci95"]
        self.assertLess(geomean["low"], expected_geomean)
        self.assertGreater(geomean["high"], expected_geomean)
        self.assertLess(geomean["high"], 1.0)
        self.assertEqual(speed["rows_faster"], 120)
        self.assertEqual(speed["fraction_faster"], 1.0)
        self.assertEqual(speed["wilcoxon"]["method"], "normal")
        self.assertEqual(speed["wilcoxon"]["w_plus"], 0.0)
        self.assertLess(speed["wilcoxon"]["p_two_sided"], 1e-15)
        self.assertAlmostEqual(speed["sign_test"]["p_two_sided"], 2.0 / 2**120, delta=1e-45)
        mean_level = math.fsum(self.levels.values()) / len(self.levels)
        self.assertAlmostEqual(speed["saving_us"]["mean"], 0.2 * mean_level, places=6)
        per_audio = speed["saving_us_per_audio_s"]
        self.assertEqual(per_audio["rows"], 120)
        # Each row saves (1 - 0.8 f) * level µs over level / 1000 s of audio: 280 or 120 µs per audio second.
        self.assertAlmostEqual(per_audio["mean"], 200.0, places=6)
        self.assertAlmostEqual(per_audio["p50"], 200.0, places=6)
        self.assertAlmostEqual(per_audio["total"], 200.0, places=6)
        self.assertGreater(speed["saving_us"]["ci95_mean"]["low"], 0.0)
        self.assertEqual(pair["noise_floor"]["within_noise_floor"], False)
        self.assertEqual(pair["equivalence"]["identical_rate"], 1.0)

    def test_aa_pair_is_automatic_and_contains_one(self):
        report = self.report()
        labels = [pair["label"] for pair in report["timing"]["pairs"]]
        self.assertEqual(labels, ["ggml vs rust", "ggml vs tiny", "ggml vs ggml@aa"])
        aa = pair_by_label(report, "ggml vs ggml@aa")
        self.assertEqual(aa["kind"], "aa")
        self.assertAlmostEqual(aa["speed"]["total_ratio"]["point"], 1.0, places=12)
        for key in ("bca", "percentile"):
            low, high = aa["speed"]["total_ratio"]["ci95"][key]
            self.assertLessEqual(low, 1.0)
            self.assertGreaterEqual(high, 1.0)
        self.assertFalse(aa["speed"]["total_ratio"]["ci95"]["excludes_null"])
        self.assertNotIn("aa_bias", warning_codes(report))

    def test_ci_overlapping_aa_is_flagged(self):
        report = self.report()
        tiny = pair_by_label(report, "ggml vs tiny")
        self.assertTrue(tiny["noise_floor"]["within_noise_floor"])
        self.assertFalse(tiny["noise_floor"]["proxy"])
        self.assertEqual({check["aa_pair"] for check in tiny["noise_floor"]["checks"]}, {"ggml vs ggml@aa"})
        self.assertIn("within_noise_floor", warning_codes(report))
        rust = pair_by_label(report, "ggml vs rust")
        self.assertTrue(all(check["overlaps"] is False for check in rust["noise_floor"]["checks"]))

    def test_all_vs_skips_aa_arms_and_adds_aa_pair(self):
        report = self.report(pairs=(), all_vs="ggml")
        labels = [pair["label"] for pair in report["timing"]["pairs"]]
        self.assertEqual(labels, ["ggml vs rust", "ggml vs tiny", "ggml vs ggml@aa"])

    def test_warmup_excluded_by_default(self):
        default = self.report()
        included = self.report(include_warmup=True)
        mean_level = math.fsum(self.levels.values()) / len(self.levels)
        self.assertEqual(default["timing"]["arms"]["ggml"]["passes"], [1, 2, 3])
        self.assertEqual(default["timing"]["arms"]["ggml"]["samples"], 360)
        self.assertAlmostEqual(default["timing"]["arms"]["ggml"]["elapsed_us"]["mean"], mean_level, places=6)
        self.assertEqual(included["timing"]["arms"]["ggml"]["passes"], [0, 1, 2, 3])
        # With the 2x warmup the median of four passes is (1.00 + 1.03) / 2 of the level.
        self.assertAlmostEqual(included["timing"]["arms"]["ggml"]["elapsed_us"]["mean"], 1.015 * mean_level, places=6)

    def test_deterministic_for_fixed_seed(self):
        first = ps.to_json(self.report(seed=7))
        second = ps.to_json(self.report(seed=7))
        self.assertEqual(first, second)
        self.assertEqual(ps.render_markdown(json.loads(first)), ps.render_markdown(json.loads(second)))
        other = json.loads(ps.to_json(self.report(seed=8)))
        same = json.loads(first)
        self.assertNotEqual(
            pair_by_label(other, "ggml vs rust")["speed"]["total_ratio"]["ci95"]["percentile"],
            pair_by_label(same, "ggml vs rust")["speed"]["total_ratio"]["ci95"]["percentile"],
        )

    def test_pair_seed_is_independent_of_other_pairs(self):
        alone = self.report(pairs=["ggml:rust"])
        together = self.report(pairs=["ggml:tiny", "ggml:rust"])
        self.assertEqual(
            pair_by_label(alone, "ggml vs rust")["speed"]["total_ratio"]["ci95"],
            pair_by_label(together, "ggml vs rust")["speed"]["total_ratio"]["ci95"],
        )

    def test_explicit_aa_pair_is_not_duplicated(self):
        report = self.report(pairs=["ggml:ggml@aa", "ggml:rust"])
        labels = [pair["label"] for pair in report["timing"]["pairs"]]
        self.assertEqual(labels, ["ggml vs ggml@aa", "ggml vs rust"])
        self.assertEqual(report["timing"]["pairs"][0]["kind"], "aa")
        self.assertIsNone(report["timing"]["pairs"][0]["noise_floor"])

    def test_other_arms_aa_is_a_proxy_noise_floor(self):
        factors = {
            "ggml": self.factors["ggml"],
            "rust": self.factors["rust"],
            "tiny": self.factors["tiny"],
            "tiny@aa": alternating(self.levels, 0.999 * 1.03, 0.999 * 0.97),
        }
        path = self.write_jsonl("proxy.jsonl", interleaved_rows(self.levels, factors))
        report = ps.analyze([path], pairs=["ggml:rust"], bootstrap=BOOTSTRAP)
        floor = pair_by_label(report, "ggml vs rust")["noise_floor"]
        self.assertTrue(floor["proxy"])
        self.assertEqual({check["aa_pair"] for check in floor["checks"]}, {"tiny vs tiny@aa"})
        self.assertFalse(floor["within_noise_floor"])

    def test_timing_and_stage_profile_together(self):
        rows = interleaved_rows(self.levels, {"ggml": self.factors["ggml"], "rust": self.factors["rust"]})
        rows.append(
            {"type": "stage_profile", "row_id": "r0", "pass": 1, "audio_s": 1.0, "stages_us": {"a": 1, "full": 2}}
        )
        path = self.write_jsonl("both.jsonl", rows)
        report = ps.analyze([path], pairs=["ggml:rust"], bootstrap=200, stage_profile=True)
        self.assertEqual(report["timing"]["pairs"][0]["n"], 120)
        self.assertEqual(report["stage_profile"]["groups"][0]["stages"][0]["share_of_full_p50"], 0.5)


class WilcoxonTests(unittest.TestCase):
    def test_exact_small_example(self):
        # |d| ranks 1..5, positive ranks {1, 3, 4, 5}: W+ = 13. Sign patterns with W+ >= 13 are the complements of
        # subsets summing to <= 2: {}, {1}, {2}, so P(W+ >= 13) = 3/32 and the two-sided p is 6/32.
        result = ps.wilcoxon_signed_rank([1.0, -2.0, 3.0, 4.0, 5.0])
        self.assertEqual(result["method"], "exact")
        self.assertEqual(result["w_plus"], 13.0)
        self.assertEqual(result["w_minus"], 2.0)
        self.assertEqual(result["p_two_sided"], 6 / 32)

    def test_exact_with_ties(self):
        # Mid-ranks 1.5, 1.5, 3, 4; W+ = 8.5. Doubled ranks {3, 3, 6, 8}: 3 of 16 subsets reach >= 17, so p = 6/16.
        result = ps.wilcoxon_signed_rank([1.0, -1.0, 2.0, 3.0])
        self.assertEqual(result["w_plus"], 8.5)
        self.assertEqual(result["p_two_sided"], 6 / 16)

    def test_exact_with_zero_pratt(self):
        # The zero takes rank 1 and is dropped; nonzero ranks {2, 3, 5, 6} positive, {4} negative: W+ = 16.
        # P(W- <= 4) over the 32 sign patterns of {2..6}: subsets {}, {2}, {3}, {4} -> 4/32, two-sided 8/32.
        result = ps.wilcoxon_signed_rank([0.0, 1.0, 2.0, -3.0, 4.0, 5.0])
        self.assertEqual(result["n_zero"], 1)
        self.assertEqual(result["w_plus"], 16.0)
        self.assertEqual(result["p_two_sided"], 8 / 32)

    def test_exact_all_one_sign(self):
        result = ps.wilcoxon_signed_rank([-0.1] * 3 + [-0.2, -0.3])
        self.assertEqual(result["w_plus"], 0.0)
        self.assertEqual(result["p_two_sided"], 2 / 32)

    def test_degenerate_all_zero(self):
        result = ps.wilcoxon_signed_rank([0.0, 0.0, 0.0])
        self.assertEqual(result["method"], "degenerate")
        self.assertEqual(result["p_two_sided"], 1.0)

    def test_normal_approximation_hand_computed(self):
        # n = 30, all positive: W+ = 465, mean = 30*31/4 = 232.5, variance = 30*31*61/24 = 2363.75.
        result = ps.wilcoxon_signed_rank([float(value) for value in range(1, 31)])
        self.assertEqual(result["method"], "normal")
        self.assertEqual(result["mean"], 232.5)
        self.assertEqual(result["variance"], 2363.75)
        z = 232.5 / math.sqrt(2363.75)
        self.assertAlmostEqual(result["z"], z, places=12)
        self.assertAlmostEqual(result["p_two_sided"], math.erfc(z / math.sqrt(2)), places=15)

    def test_normal_tie_and_zero_corrections(self):
        # 2 zeros, a tie group of 3 and a tie group of 2 among the nonzero magnitudes, n = 30.
        values = [0.0, 0.0, 1.0, -1.0, 1.0, 2.0, -2.0] + [float(value) for value in range(3, 26)]
        result = ps.wilcoxon_signed_rank(values)
        n, zeros = 30, 2
        mean = (n * (n + 1) - zeros * (zeros + 1)) / 4
        variance = (n * (n + 1) * (2 * n + 1) - zeros * (zeros + 1) * (2 * zeros + 1)) / 24 - ((27 - 3) + (8 - 2)) / 48
        self.assertEqual(result["mean"], mean)
        self.assertAlmostEqual(result["variance"], variance, places=9)
        # The corrected variance equals the exact conditional variance sum(rank^2) / 4 of the nonzero mid-ranks.
        ranks = ps.average_ranks([abs(value) for value in values])
        conditional = math.fsum(rank * rank for rank, value in zip(ranks, values, strict=True) if value != 0.0) / 4
        self.assertAlmostEqual(result["variance"], conditional, places=9)

    def test_normal_close_to_exact_for_moderate_n(self):
        rng = random.Random(3)
        values = [rng.gauss(0.15, 1.0) for _ in range(40)]
        normal = ps.wilcoxon_signed_rank(values)
        exact = ps.wilcoxon_signed_rank(values, exact_max_n=40)
        self.assertEqual((normal["method"], exact["method"]), ("normal", "exact"))
        self.assertAlmostEqual(normal["p_two_sided"], exact["p_two_sided"], delta=0.01)

    def test_exact_matches_brute_force_enumeration(self):
        values = [0.5, -0.25, 0.5, 1.5, -2.0, 0.0, 3.0, -0.25]
        ranks = ps.average_ranks([abs(value) for value in values])
        nonzero = [(rank, value) for rank, value in zip(ranks, values, strict=True) if value != 0.0]
        observed = sum(rank for rank, value in nonzero if value > 0)
        sums = []
        for mask in range(1 << len(nonzero)):
            sums.append(sum(rank for bit, (rank, _) in enumerate(nonzero) if mask >> bit & 1))
        lower = sum(1 for total in sums if total <= observed)
        upper = sum(1 for total in sums if total >= observed)
        expected = min(1.0, 2 * min(lower, upper) / len(sums))
        self.assertEqual(ps.wilcoxon_signed_rank(values)["p_two_sided"], expected)


class SignTestTests(unittest.TestCase):
    def test_exact_binomial(self):
        self.assertEqual(ps.sign_test(9, 1)["p_two_sided"], 2 * (1 + 10) / 1024)
        self.assertEqual(ps.sign_test(1, 9)["p_two_sided"], 2 * (1 + 10) / 1024)
        self.assertEqual(ps.sign_test(5, 5)["p_two_sided"], 1.0)
        self.assertEqual(ps.sign_test(0, 0)["p_two_sided"], 1.0)
        self.assertEqual(ps.sign_test(0, 1)["p_two_sided"], 1.0)
        self.assertEqual(ps.sign_test(2000, 0)["p_two_sided"], 0.0)


class BcaTests(unittest.TestCase):
    def test_acceleration_of_the_mean_matches_skewness_identity(self):
        data = [1.0, 2.0, 3.0, 10.0]
        jackknife = [(math.fsum(data) - value) / (len(data) - 1) for value in data]
        # For the mean, theta_bar - theta_(i) = (x_i - mean) / (n - 1), so a = sum(dev^3) / (6 sum(dev^2)^1.5).
        self.assertAlmostEqual(ps.jackknife_acceleration(jackknife), 180.0 / (6.0 * 50.0**1.5), places=15)

    def test_reduces_to_percentile_without_bias_or_skew(self):
        replicates = [index / 1000 for index in range(1001)]
        interval = ps.bootstrap_interval(0.5, replicates, [-1.0, 0.0, 1.0], null=0.0)
        self.assertEqual(interval["bca_z0"], 0.0)
        self.assertEqual(interval["bca_acceleration"], 0.0)
        self.assertAlmostEqual(interval["bca_adjusted_probabilities"][0], 0.025, places=12)
        self.assertAlmostEqual(interval["bca_adjusted_probabilities"][1], 0.975, places=12)
        for got, want in zip(interval["bca"], interval["percentile"], strict=True):
            self.assertAlmostEqual(got, want, places=12)
        for got, want in zip(interval["percentile"], (0.025, 0.975), strict=True):
            self.assertAlmostEqual(got, want, places=12)

    def test_adjusted_probabilities_for_known_acceleration(self):
        # jackknife [0, 0, 0, 1]: deviations (0.25, 0.25, 0.25, -0.75) give a = -0.375 / (6 * 0.75^1.5).
        replicates = [index / 1000 for index in range(1001)]
        interval = ps.bootstrap_interval(0.5, replicates, [0.0, 0.0, 0.0, 1.0], null=0.0)
        acceleration = -0.375 / (6.0 * 0.75**1.5)
        self.assertAlmostEqual(interval["bca_acceleration"], acceleration, places=15)
        z = 1.959963984540054
        low = 0.5 * math.erfc((z / (1.0 + acceleration * z)) / math.sqrt(2))
        high = 1.0 - 0.5 * math.erfc((z / (1.0 - acceleration * z)) / math.sqrt(2))
        self.assertAlmostEqual(interval["bca_adjusted_probabilities"][0], low, places=12)
        self.assertAlmostEqual(interval["bca_adjusted_probabilities"][1], high, places=12)
        self.assertAlmostEqual(interval["bca"][0], low, places=9)
        self.assertAlmostEqual(interval["bca"][1], high, places=9)

    def test_right_skewed_mean_shifts_right(self):
        rng = random.Random(5)
        data = [rng.expovariate(1.0) for _ in range(40)]
        point = math.fsum(data) / len(data)
        draw = random.Random(9)
        replicates = [math.fsum(draw.choice(data) for _ in data) / len(data) for _ in range(4000)]
        jackknife = [(math.fsum(data) - value) / (len(data) - 1) for value in data]
        interval = ps.bootstrap_interval(point, replicates, jackknife, null=0.0)
        self.assertGreater(interval["bca_acceleration"], 0.0)
        self.assertGreater(interval["bca_z0"], 0.0)
        self.assertGreater(interval["bca"][0], interval["percentile"][0])
        self.assertGreater(interval["bca"][1], interval["percentile"][1])
        self.assertLess(interval["bca"][0], point)
        self.assertGreater(interval["bca"][1], point)
        self.assertGreaterEqual(interval["bca"][0], min(replicates))
        self.assertLessEqual(interval["bca"][1], max(replicates))

    def test_singular_transform_falls_back_to_percentile(self):
        # |a| <= 1/6, so 1 - a * (z0 + z) <= 0 needs |z0 + z| >= 6: a point below all 40000 replicates gives
        # z0 = inv_cdf(0.5 / 40000) ~ -4.2, and one dominant negative jackknife deviation gives a ~ -1/6.
        replicates = [1.0 + index / 40000 for index in range(40000)]
        interval = ps.bootstrap_interval(0.0, replicates, [0.0] * 9999 + [1e6], null=0.0)
        self.assertIsNone(interval["bca"])
        self.assertLess(interval["bca_z0"], -4.0)
        self.assertAlmostEqual(interval["bca_acceleration"], -1.0 / 6.0, places=3)
        self.assertIn("singular", interval["bca_reason"])
        self.assertEqual(interval["method"], "percentile")
        self.assertEqual([interval["low"], interval["high"]], interval["percentile"])


class EquivalenceTests(TempDirTestCase):
    def rows(self):
        rows = [run_meta(["ref", "new"], passes=2)]
        seq = 0
        for pass_index in (0, 1, 2):
            for index in range(25):
                row = f"r{index}"
                rows.append(timing_row("ref", row, pass_index, seq, 1000.0 + index, sha=f"h{index}"))
                seq += 1
                sha = f"h{index}"
                equal_ref = True
                if 20 <= index <= 22:
                    sha, equal_ref = f"x{index}", False
                elif index == 23:
                    sha, equal_ref = (f"h{index}", True) if pass_index == 1 else (f"y{index}", False)
                elif index == 24:
                    sha, equal_ref = None, None
                max_abs = float("nan") if (index, pass_index) == (5, 2) else index * 1e-6
                err = {"max_abs": max_abs, "rel_l2": index * 1e-7}
                rows.append(
                    timing_row("new", row, pass_index, seq, 900.0 + index, sha=sha, equal_ref=equal_ref, err=err)
                )
                seq += 1
        return rows

    def test_counts(self):
        path = self.write_jsonl("equivalence.jsonl", self.rows())
        report = ps.analyze([path], pairs=["ref:new"], bootstrap=200)
        equivalence = pair_by_label(report, "ref vs new")["equivalence"]
        self.assertEqual(equivalence["rows"], 25)
        self.assertEqual(equivalence["compared"], 24)
        self.assertEqual(equivalence["identical"], 20)
        self.assertEqual(equivalence["identical_rate"], 20 / 24)
        self.assertEqual(equivalence["mismatched"], {"count": 4, "row_ids": ["r20", "r21", "r22", "r23"]})
        self.assertEqual(equivalence["hash_missing"], {"count": 1, "row_ids": ["r24"]})
        new = report["timing"]["arms"]["new"]["equivalence"]
        self.assertEqual(new["equal_ref"]["true"], 20)
        self.assertEqual(new["equal_ref"]["false"], 4)
        self.assertEqual(new["equal_ref"]["null"], 1)
        self.assertEqual(new["equal_ref"]["rate"], 20 / 24)
        self.assertEqual(new["equal_ref"]["false_rows"]["row_ids"], ["r20", "r21", "r22", "r23"])
        self.assertEqual(new["nondeterministic_rows"], {"count": 1, "row_ids": ["r23"]})
        self.assertEqual(new["err"]["max_abs"]["max"], 24 * 1e-6)
        self.assertEqual(new["err"]["max_abs"]["row_id"], "r24")
        self.assertEqual(new["err"]["max_abs"]["nonfinite_samples"], 1)
        self.assertEqual(new["err"]["rel_l2"]["max"], 24 * 1e-7)
        self.assertEqual(report["timing"]["arms"]["ref"]["equivalence"]["equal_ref"]["rate"], 1.0)
        self.assertIsNone(report["timing"]["arms"]["ref"]["equivalence"]["err"]["max_abs"])
        codes = warning_codes(report)
        self.assertIn("nondeterministic_output", codes)
        self.assertIn("err_nonfinite", codes)
        self.assertIn("hash_missing", codes)
        self.assertIn("no_aa", codes)

    def test_mismatch_list_is_capped(self):
        rows = []
        for index in range(30):
            rows.append(timing_row("a", index, 1, 2 * index, 100.0, sha="a"))
            rows.append(timing_row("b", index, 1, 2 * index + 1, 90.0, sha="b"))
        path = self.write_jsonl("capped.jsonl", rows)
        report = ps.analyze([path], pairs=["a:b"], bootstrap=200)
        mismatched = pair_by_label(report, "a vs b")["equivalence"]["mismatched"]
        self.assertEqual(mismatched["count"], 30)
        self.assertEqual(mismatched["row_ids"], [str(index) for index in range(20)])


class StageProfileTests(TempDirTestCase):
    def test_shares_and_consistency(self):
        def stage(row_id, pass_index, stages, counts=None, audio_s=2.0):
            return {
                "type": "stage_profile",
                "row_id": row_id,
                "pass": pass_index,
                "audio_s": audio_s,
                "stages_us": stages,
                "counts": counts or {},
            }

        rows = [
            stage("s0", 0, {"mel": 900, "encoder": 900, "decoder": 900, "full": 9000}),
            stage("s0", 1, {"mel": 10, "encoder": 60, "decoder": 20, "full": 100}, {"tokens": 4}),
            stage("s0", 2, {"mel": 12, "encoder": 58, "decoder": 20, "full": 100}, {"tokens": 4}),
            stage("s1", 1, {"mel": 20, "encoder": 100, "decoder": 60, "full": 200}, {"tokens": 8}),
            stage("s2", 1, {"mel": 30, "encoder": 200, "decoder": 90, "full": 300}, {"tokens": 12}),
            stage("s3", 1, {"mel": 5, "encoder": 30}),
        ]
        path = self.write_jsonl("stages.jsonl", rows)
        report = ps.analyze([path], stage_profile=True)
        self.assertIsNone(report["timing"])
        group = report["stage_profile"]["groups"][0]
        self.assertEqual((group["group"], group["rows"], group["samples"]), ("all", 4, 5))
        stages = {item["stage"]: item for item in group["stages"]}
        self.assertEqual(list(stages), ["mel", "encoder", "decoder", "(unattributed)", "full"])
        self.assertAlmostEqual(stages["mel"]["share_of_full_p50"], 0.1, places=12)
        self.assertAlmostEqual(stages["encoder"]["share_of_full_p50"], 0.59, places=12)
        self.assertAlmostEqual(stages["decoder"]["share_of_full_p50"], 0.3, places=12)
        self.assertAlmostEqual(stages["(unattributed)"]["share_of_full_p50"], 0.1, places=12)
        self.assertEqual(stages["full"]["share_of_full_p50"], 1.0)
        self.assertAlmostEqual(stages["mel"]["share_of_total_full"], 61 / 600, places=12)
        self.assertAlmostEqual(stages["encoder"]["share_of_total_full"], 359 / 600, places=12)
        self.assertEqual(stages["mel"]["rows"], 4)
        self.assertEqual(stages["mel"]["share_rows"], 3)
        self.assertEqual(stages["mel"]["p50_us"], 15.5)
        self.assertEqual(stages["mel"]["p50_ms"], 0.0155)
        self.assertEqual(stages["encoder"]["mean_us"], (59 + 100 + 200 + 30) / 4)
        self.assertEqual(stages["mel"]["us_per_audio_s_p50"], 7.75)
        consistency = group["consistency"]
        self.assertEqual(consistency["samples_checked"], 4)
        self.assertEqual(consistency["samples_missing_full"], 1)
        self.assertEqual(consistency["over_full"]["count"], 1)
        self.assertEqual(consistency["over_full"]["examples"][0]["row_id"], "s2")
        self.assertAlmostEqual(consistency["over_full"]["examples"][0]["coverage"], 320 / 300, places=12)
        self.assertEqual(consistency["coverage"]["min"], 0.9)
        self.assertFalse(consistency["consistent"])
        self.assertEqual(group["counts"]["tokens"]["total"], 24.0)
        self.assertEqual(group["counts"]["tokens"]["rows"], 3)
        codes = warning_codes(report)
        self.assertIn("stage_overcount", codes)
        self.assertIn("stage_missing_full", codes)
        self.assertIn("## Stage profile: all", ps.render_markdown(report))


class InputHandlingTests(TempDirTestCase):
    def test_dropped_rows_and_common_set(self):
        rows = []
        for index in range(12):
            rows.append(timing_row("a", f"q{index}", 1, 2 * index, 100.0))
            if index not in (3, 7, 9):
                rows.append(timing_row("b", f"q{index}", 1, 2 * index + 1, 80.0))
        rows.append(timing_row("b", "extra", 1, 99, 80.0))
        path = self.write_jsonl("dropped.jsonl", rows)
        report = ps.analyze([path], pairs=["a:b"], bootstrap=200)
        pair = pair_by_label(report, "a vs b")
        self.assertEqual(pair["n"], 9)
        self.assertEqual(pair["dropped_rows"]["base_only"], {"count": 3, "row_ids": ["q3", "q7", "q9"]})
        self.assertEqual(pair["dropped_rows"]["cand_only"], {"count": 1, "row_ids": ["extra"]})
        self.assertIn("dropped_rows", warning_codes(report))
        self.assertEqual(pair["speed"]["total_ratio"]["point"], 0.8)

    def test_aggregate_median_and_min(self):
        rows = []
        for pass_index, (a, b) in enumerate([(50.0, 50.0), (300.0, 30.0), (100.0, 20.0), (200.0, 10.0)]):
            rows.append(timing_row("a", "only", pass_index, 2 * pass_index, a))
            rows.append(timing_row("b", "only", pass_index, 2 * pass_index + 1, b))
        path = self.write_jsonl("aggregate.jsonl", rows)
        median = ps.analyze([path], pairs=["a:b"], bootstrap=50)
        minimum = ps.analyze([path], pairs=["a:b"], bootstrap=50, aggregate="min")
        self.assertEqual(median["timing"]["arms"]["a"]["elapsed_us"]["p50"], 200.0)
        self.assertEqual(median["timing"]["arms"]["b"]["elapsed_us"]["p50"], 20.0)
        self.assertEqual(minimum["timing"]["arms"]["a"]["elapsed_us"]["p50"], 100.0)
        self.assertEqual(minimum["timing"]["arms"]["b"]["elapsed_us"]["p50"], 10.0)
        pair = pair_by_label(median, "a vs b")
        self.assertIsNone(pair["speed"]["total_ratio"]["ci95"])
        self.assertIn("small_n", warning_codes(median))

    def test_per_arm_distribution(self):
        rows = [timing_row("a", index, 1, index, float(index + 1), audio_s=0.5) for index in range(100)]
        rows += [timing_row("b", index, 1, 100 + index, float(index + 1), audio_s=0.5) for index in range(100)]
        path = self.write_jsonl("distribution.jsonl", rows)
        report = ps.analyze([path], pairs=["a:b"], bootstrap=100)
        arm = report["timing"]["arms"]["a"]
        stats = arm["elapsed_us"]
        self.assertEqual(stats["n"], 100)
        self.assertEqual(stats["mean"], 50.5)
        self.assertEqual(stats["p50"], 50.5)
        self.assertAlmostEqual(stats["p90"], 90.1, places=12)
        self.assertAlmostEqual(stats["p95"], 95.05, places=12)
        self.assertAlmostEqual(stats["p99"], 99.01, places=12)
        self.assertEqual((stats["min"], stats["max"]), (1.0, 100.0))
        self.assertEqual(arm["us_per_audio_s"]["p50"], 101.0)
        self.assertEqual(arm["total_us_per_audio_s"], 101.0)
        self.assertEqual(arm["audio_s_total"], 50.0)

    def test_drift_is_flagged(self):
        rows = []
        seq = 0
        for pass_index in range(1, 4):
            for index in range(20):
                for arm in ("a", "b"):
                    rows.append(timing_row(arm, index, pass_index, seq, 1000.0 + 10.0 * seq))
                    seq += 1
        path = self.write_jsonl("drift.jsonl", rows)
        report = ps.analyze([path], pairs=["a:b"], bootstrap=200)
        drift = {item["arm"]: item for item in report["timing"]["drift"]}
        self.assertEqual(drift["a"]["n"], 60)
        self.assertAlmostEqual(drift["a"]["rho"], 1.0, places=12)
        self.assertGreater(drift["a"]["rho_row_normalized"], 0.3)
        self.assertTrue(drift["a"]["warn"])
        self.assertIn("drift", warning_codes(report))

    def test_no_drift_for_shuffled_order(self):
        levels = paired_levels(pairs=30)
        factors = {"a": dict.fromkeys(levels, 1.0), "b": dict.fromkeys(levels, 0.9)}
        path = self.write_jsonl("shuffled.jsonl", interleaved_rows(levels, factors))
        report = ps.analyze([path], pairs=["a:b"], bootstrap=200)
        for item in report["timing"]["drift"]:
            self.assertLess(abs(item["rho"]), ps.DRIFT_RHO_THRESHOLD)
            self.assertLess(abs(item["rho_row_normalized"]), ps.DRIFT_RHO_THRESHOLD)
        self.assertNotIn("drift", warning_codes(report))

    def test_corpora_are_namespaced(self):
        first = [run_meta(["a", "b"], corpus="general96", passes=1)]
        second = [run_meta(["a", "b"], corpus="jargon456", passes=1)]
        for index in range(5):
            for rows, value in ((first, 100.0), (second, 200.0)):
                for pass_index in (0, 1):
                    seq = 4 * index + 2 * pass_index
                    rows.append(timing_row("a", index, pass_index, seq, value))
                    rows.append(timing_row("b", index, pass_index, seq + 1, 0.5 * value))
        report = ps.analyze(
            [self.write_jsonl("g.jsonl", first), self.write_jsonl("j.jsonl", second)], pairs=["a:b"], bootstrap=100
        )
        self.assertEqual(
            report["timing"]["row_identity"], {"key": "corpus/row_id", "corpora": ["general96", "jargon456"]}
        )
        pair = pair_by_label(report, "a vs b")
        self.assertEqual(pair["n"], 10)
        self.assertEqual(pair["equivalence"]["rows"], 10)
        self.assertEqual(len(report["timing"]["drift"]), 4)

    def test_bet_collision_is_rejected(self):
        rows = [timing_row("rust", 1, 1, 1, 10.0, bet="B1"), timing_row("rust", 2, 1, 2, 10.0, bet="B2")]
        path = self.write_jsonl("bets.jsonl", rows)
        with self.assertRaises(ps.InputError):
            ps.analyze([path], pairs=["rust:rust"])

    def test_invalid_samples_are_excluded(self):
        rows = [
            timing_row("a", 1, 1, 1, 100.0),
            timing_row("b", 1, 1, 2, 90.0),
            timing_row("a", 2, 1, 3, 100.0),
            timing_row("b", 2, 1, 4, None),
            timing_row("b", 3, 1, 5, -1.0),
            {"type": "heartbeat"},
        ]
        path = self.write_jsonl("invalid.jsonl", rows)
        report = ps.analyze([path], pairs=["a:b"], bootstrap=100)
        self.assertEqual(report["timing"]["invalid_samples"]["count"], 2)
        self.assertEqual(pair_by_label(report, "a vs b")["n"], 1)
        self.assertIn("invalid_samples", warning_codes(report))
        self.assertIn("ignored_rows", warning_codes(report))

    def test_pair_parsing(self):
        rows = [timing_row("x:y", 1, 1, 1, 10.0), timing_row("z", 1, 1, 2, 9.0)]
        path = self.write_jsonl("colon.jsonl", rows)
        report = ps.analyze([path], pairs=["x:y:z"], bootstrap=10)
        self.assertEqual(report["timing"]["pairs"][0]["label"], "x:y vs z")
        with self.assertRaises(ps.InputError):
            ps.analyze([path], pairs=["x:nope"])
        with self.assertRaises(ps.InputError):
            ps.analyze([path], pairs=["z"])


class RunIntegrityTests(TempDirTestCase):
    def analyze(self, rows, name="run.jsonl", **kwargs):
        options = {"pairs": ["base:cand"], "bootstrap": 50}
        options.update(kwargs)
        return ps.analyze([self.write_jsonl(name, rows)], **options)

    def test_truncated_pass_grid_is_refused(self):
        # The interrupted B4 run: every arm present, no error line, but 7 of the 96 declared cells were never written.
        rows = grid_rows()[:-7]
        with self.assertRaisesRegex(ps.InputError, r"incomplete grid: 89 of 96 declared cells written"):
            self.analyze(rows)

    def test_truncated_run_exits_with_status_two(self):
        path = self.write_jsonl("cut.jsonl", grid_rows()[:-7])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(ps.main([path, "--pair", "base:cand", "--bootstrap", "50"]), 2)
        self.assertIn("run integrity check failed", stderr.getvalue())
        self.assertIn("incomplete grid", stderr.getvalue())

    def test_duplicate_key_is_refused(self):
        rows = grid_rows()
        rows.append(timing_row("base", "q0", 2, 999, 5.0))
        pattern = r"1 duplicate \(arm, row_id, pass\) keys \(first: \(base, q0, 2\)\)"
        with self.assertRaisesRegex(ps.InputError, pattern):
            self.analyze(rows)

    def test_arm_sets_must_match_run_meta(self):
        rows = grid_rows()
        rows[0]["arms"] = ["base", "cand", "ghost"]
        with self.assertRaisesRegex(ps.InputError, r"declared but never written \['ghost'\]"):
            self.analyze(rows)
        rows = grid_rows()
        rows[0]["arms"] = ["base"]
        with self.assertRaisesRegex(ps.InputError, r"written but not declared \['cand'\]"):
            self.analyze(rows)

    def test_pass_beyond_declared_passes_is_refused(self):
        rows = grid_rows(passes=3)
        rows[0]["passes"] = 2
        with self.assertRaisesRegex(ps.InputError, r"pass indices \[3\] exceed run_meta.passes=2"):
            self.analyze(rows)

    def test_missing_footer_is_refused_when_completion_is_required(self):
        rows = grid_rows(completion_required=True)
        with self.assertRaisesRegex(ps.InputError, "completion_required is true but the file has no run_end footer"):
            self.analyze(rows)

    def test_run_killed_right_after_run_meta_is_refused(self):
        rows = [run_meta(["base", "cand"], completion_required=True)]
        with self.assertRaisesRegex(ps.InputError, "no run_end footer"):
            self.analyze(rows)

    def test_footer_must_match_the_file(self):
        base = grid_rows(completion_required=True)
        cases = (
            ("written count", run_end(96, written=95), r"written_timing_rows=95 but the file holds 96 timing rows"),
            ("short run", run_end(100, written=96), r"96 of 100 expected timing rows written"),
            ("count above file", run_end(97), r"written_timing_rows=97 but the file holds 96 timing rows"),
            ("aborted", run_end(96, status="aborted"), r"run_end.status is 'aborted'"),
            ("empty footer", {"type": "run_end"}, r"no non-negative integer expected_timing_rows"),
            ("no failures count", {k: v for k, v in run_end(96).items() if k != "failures"}, r"no failures count"),
        )
        for name, footer, pattern in cases:
            with self.subTest(name), self.assertRaisesRegex(ps.InputError, pattern):
                self.analyze([*base, footer])

    def test_rows_after_the_footer_are_refused(self):
        rows = [*grid_rows(completion_required=True), run_end(96), timing_row("base", "q0", 2, 999, 5.0)]
        with self.assertRaisesRegex(ps.InputError, "rows follow the run_end footer"):
            self.analyze(rows)

    def test_valid_footer_verifies_the_run(self):
        rows = [*grid_rows(completion_required=True, executable_sha256="ab" * 32), run_end(96)]
        report = self.analyze(rows)
        integrity = report["integrity"][0]
        self.assertEqual((integrity["status"], integrity["footer"]), ("verified", "valid"))
        self.assertEqual(integrity["grid"]["expected_cells"], 96)
        self.assertEqual(report["inputs"][0]["run_end"], [run_end(96)])
        codes = warning_codes(report)
        self.assertNotIn("incomplete_provenance", codes)
        self.assertNotIn("no_executable_fingerprint", codes)
        self.assertEqual(pair_by_label(report, "base vs cand")["n"], 12)

    def test_footer_field_aliases_of_the_combined_harness(self):
        footer = {
            "type": "run_end",
            "status": "complete",
            "expected_timing_rows": 96,
            "timing_rows": 96,
            "failed_calls": 0,
        }
        report = self.analyze([*grid_rows(completion_required=True), footer])
        self.assertEqual(report["integrity"][0]["status"], "verified")
        with self.assertRaisesRegex(ps.InputError, "run_end.status is 'invalid'"):
            self.analyze([*grid_rows(completion_required=True), dict(footer, status="invalid")])

    def test_footer_failures_warn_and_the_strict_gate_refuses(self):
        rows = [*grid_rows(completion_required=True), run_end(96, failures=3)]
        codes = warning_codes(self.analyze(rows))
        self.assertIn("run_reported_failures", codes)
        self.assertIn("run_failures_mismatch", codes)
        with self.assertRaisesRegex(ps.InputError, "run_end reports 3 failed calls"):
            self.analyze(rows, check=True)

    def test_legacy_complete_file_is_analyzed_with_a_provenance_warning(self):
        report = self.analyze(grid_rows())
        integrity = report["integrity"][0]
        self.assertEqual((integrity["status"], integrity["footer"]), ("grid_only", "missing"))
        warning = next(item for item in report["warnings"] if item["code"] == "incomplete_provenance")
        self.assertIn("run_end", warning["message"])
        self.assertEqual(pair_by_label(report, "base vs cand")["n"], 12)
        self.assertIn("## Run integrity", ps.render_markdown(report))

    def test_a_whole_omitted_row_is_visible_only_to_the_footer(self):
        rows = grid_rows(row_ids=GRID_ROWS[:11], completion_required=True)
        with self.assertRaisesRegex(ps.InputError, "88 of 96 expected timing rows written"):
            self.analyze([*rows, run_end(96, written=88)])
        legacy = self.analyze(grid_rows(row_ids=GRID_ROWS[:11]))
        self.assertEqual(legacy["integrity"][0]["status"], "grid_only")
        self.assertEqual(pair_by_label(legacy, "base vs cand")["n"], 11)

    def test_file_without_run_meta_cannot_be_checked(self):
        report = self.analyze(grid_rows(meta=False)[:-7])
        self.assertEqual(report["integrity"][0]["status"], "unchecked")
        self.assertIn("incomplete_provenance", warning_codes(report))

    def test_files_with_disjoint_arms_are_checked_separately(self):
        inproc = self.write_jsonl("inproc.jsonl", grid_rows(arms=("swift", "swift@aa")))
        rust = self.write_jsonl("rust.jsonl", grid_rows(arms=("rust",)))
        report = ps.analyze([inproc, rust], pairs=["swift:rust"], bootstrap=50)
        self.assertEqual([item["status"] for item in report["integrity"]], ["grid_only", "grid_only"])
        self.assertEqual(pair_by_label(report, "swift vs rust")["n"], 12)

    def test_one_arm_is_never_pooled_across_files(self):
        first = self.write_jsonl("first.jsonl", grid_rows())
        second = self.write_jsonl("second.jsonl", grid_rows())
        with self.assertRaisesRegex(ps.InputError, "never pooled"):
            ps.analyze([first, second], pairs=["base:cand"], bootstrap=50)

    def test_power_and_executable_fingerprint_warnings(self):
        def codes(**meta):
            return warning_codes(self.analyze(grid_rows(**meta)))

        self.assertIn("non_ac_power", codes(power="Battery Power"))
        self.assertIn("non_ac_power", codes(power="battery"))
        self.assertIn("non_ac_power", codes(power=""))
        self.assertNotIn("non_ac_power", codes(power="AC Power"))
        self.assertNotIn("non_ac_power", codes(power="AC"))
        self.assertIn("no_executable_fingerprint", codes())
        self.assertIn("no_executable_fingerprint", codes(executable_sha256="short"))
        self.assertNotIn("no_executable_fingerprint", codes(executable_sha256="0123456789abcdef" * 4))


class RuntimeErrorTests(TempDirTestCase):
    def analyze(self, rows, **kwargs):
        options = {"pairs": ["base:cand"], "bootstrap": 50}
        options.update(kwargs)
        return ps.analyze([self.write_jsonl("run.jsonl", rows)], **options)

    def test_work_error_rows_are_counted_and_never_become_zero_time(self):
        rows = grid_rows()
        mark_failed(rows, "cand", {"q0", "q1", "q2", "q3"})
        report = self.analyze(rows)
        timing = report["timing"]
        errors = timing["runtime_errors"]["by_arm"]["cand"]
        self.assertEqual(timing["runtime_errors"]["count"], 16)
        self.assertEqual((errors["samples"], errors["rows"], errors["dropped_rows"]), (16, 4, 4))
        self.assertEqual(errors["kinds"], {"error": 16})
        self.assertIn("BlockMMA", errors["first"])
        self.assertEqual(timing["invalid_samples"]["count"], 0)
        self.assertEqual((timing["arms"]["cand"]["rows"], timing["arms"]["cand"]["runtime_error_samples"]), (8, 16))
        pair = pair_by_label(report, "base vs cand")
        self.assertEqual(pair["n"], 8)
        self.assertEqual(pair["dropped_rows"]["base_only"]["count"], 4)
        self.assertAlmostEqual(pair["speed"]["total_ratio"]["point"], 0.8, places=12)
        codes = warning_codes(report)
        self.assertIn("runtime_errors", codes)
        self.assertIn("dropped_rows", codes)
        self.assertNotIn("invalid_samples", codes)
        markdown = ps.render_markdown(report)
        self.assertIn("## Runtime errors", markdown)
        self.assertEqual(ps.render_markdown(json.loads(ps.to_json(report))), markdown)

    def test_non_finite_output_is_excluded_even_with_a_positive_elapsed(self):
        rows = grid_rows()
        mark_failed(rows, "cand", {"q0"}, work={"non_finite": 2}, elapsed=800.0)
        report = self.analyze(rows)
        self.assertEqual(report["timing"]["runtime_errors"]["by_arm"]["cand"]["kinds"], {"non_finite": 4})
        self.assertEqual(pair_by_label(report, "base vs cand")["n"], 11)

    def test_an_arm_that_always_fails_stays_visible_without_statistics(self):
        rows = grid_rows()
        mark_failed(rows, "cand", set(GRID_ROWS))
        report = self.analyze(rows, pairs=(), all_vs="base")
        cand = report["timing"]["arms"]["cand"]
        self.assertEqual((cand["rows"], cand["elapsed_us"]), (0, {"n": 0}))
        pair = pair_by_label(report, "base vs cand")
        self.assertEqual(pair["error"], "no common rows")
        self.assertNotIn("speed", pair)
        codes = warning_codes(report)
        self.assertIn("arm_without_rows", codes)
        self.assertIn("no_common_rows", codes)
        self.assertIn("Pairs without common rows: base vs cand", ps.render_markdown(report))

    def test_a_warmup_only_failure_is_counted_but_keeps_the_row(self):
        rows = grid_rows()
        mark_failed(rows, "cand", {"q0"}, passes={0})
        report = self.analyze(rows)
        self.assertEqual(report["timing"]["runtime_errors"]["count"], 1)
        self.assertEqual(report["timing"]["runtime_errors"]["by_arm"]["cand"]["dropped_rows"], 0)
        self.assertEqual(pair_by_label(report, "base vs cand")["n"], 12)
        included = self.analyze(rows, include_warmup=True)
        self.assertEqual(pair_by_label(included, "base vs cand")["n"], 11)

    def test_strict_check_refuses_runtime_errors(self):
        rows = grid_rows()
        mark_failed(rows, "cand", {"q0"})
        path = self.write_jsonl("failed.jsonl", rows)
        with self.assertRaisesRegex(ps.InputError, "4 timing rows report a runtime error"):
            ps.analyze([path], check=True)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(ps.main(["--check", path]), 2)

    def test_strict_check_alone_prints_the_integrity_summary(self):
        path = self.write_jsonl("clean.jsonl", grid_rows())
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = ps.main(["--check", path])
        self.assertEqual(code, 0)
        self.assertIn("grid_only", stdout.getvalue())
        self.assertIn("96/96 cells", stdout.getvalue())
        self.assertIn("incomplete_provenance", stderr.getvalue())

    def test_zero_elapsed_is_excluded_and_reported_not_replaced(self):
        rows = grid_rows()
        for row in rows:
            if row["type"] == "timing" and (row["arm"], row["row_id"], row["pass"]) == ("cand", "q0", 2):
                row["elapsed_us"] = 0.0
        report = self.analyze(rows)
        invalid = report["timing"]["invalid_samples"]
        self.assertEqual((invalid["count"], invalid["zero_elapsed"], invalid["by_reason"]), (1, 1, {"zero": 1}))
        self.assertEqual(report["timing"]["arms"]["cand"]["samples"], 35)
        self.assertEqual(report["timing"]["runtime_errors"]["count"], 0)
        pair = pair_by_label(report, "base vs cand")
        self.assertEqual(pair["n"], 12)
        self.assertAlmostEqual(pair["speed"]["total_ratio"]["point"], 0.8, places=12)
        message = next(item["message"] for item in report["warnings"] if item["code"] == "invalid_samples")
        self.assertIn("exactly 0", message)


def ledger_rows(*, passes=2, row_ids=("s0", "s1", "s2", "s3")):
    """A stage-profile ledger as `voiceour-bench stage-profile` writes it: wav_read, assemble, cleanup and repair run
    outside `full`; only mel + encode + tail (here 90 of 100 us) are inside it."""
    rows = [run_meta(["native-full"], passes=passes, bet="B0")]
    for pass_index in range(passes + 1):
        for row_id in row_ids:
            stages = {
                "wav_read": 5,
                "mel": 10,
                "encode": 60,
                "tail": 20,
                "assemble": 1,
                "full": 100,
                "cleanup": 2,
                "repair": 7,
            }
            rows.append(
                {
                    "type": "stage_profile",
                    "row_id": row_id,
                    "pass": pass_index,
                    "audio_s": 2.0,
                    "stages_us": stages,
                    "counts": {"n_tokens": 4},
                }
            )
            rows.append({"type": "sidecar_rt", "row_id": row_id, "pass": pass_index})
    return rows


class StageScopeTests(TempDirTestCase):
    def report(self, rows, **kwargs):
        return ps.analyze([self.write_jsonl("ledger.jsonl", rows)], stage_profile=True, **kwargs)

    @staticmethod
    def stages(report):
        return {item["stage"]: item for item in report["stage_profile"]["groups"][0]["stages"]}

    def test_nested_stage_sum_overcounts_without_part_selection(self):
        report = self.report(ledger_rows())
        group = report["stage_profile"]["groups"][0]
        self.assertEqual(group["scope"]["mode"], "all_non_full")
        self.assertEqual(group["outside_full"], [])
        # Seven non-full stages sum to 105 us of a 100 us full: the "outside full" stages are counted as inside it.
        self.assertEqual(self.stages(report)["(unattributed)"]["p50_us"], -5.0)
        self.assertEqual(group["consistency"]["over_full"]["count"], 8)
        self.assertFalse(group["consistency"]["consistent"])
        message = next(item["message"] for item in report["warnings"] if item["code"] == "stage_overcount")
        self.assertIn("--stage-parts", message)

    def test_selected_parts_scope_stages_to_full_and_list_the_rest_separately(self):
        report = self.report(ledger_rows(), stage_parts=["mel", "encode", "tail"])
        group = report["stage_profile"]["groups"][0]
        outside_names = ["wav_read", "assemble", "cleanup", "repair"]
        self.assertEqual(
            group["scope"],
            {"mode": "selected_parts", "parts": ["mel", "encode", "tail"], "outside_full": outside_names},
        )
        stages = self.stages(report)
        self.assertEqual(list(stages), ["mel", "encode", "tail", "(unattributed)", "full"])
        self.assertEqual(stages["(unattributed)"]["p50_us"], 10.0)
        self.assertEqual(stages["full"]["p50_us"], 100.0)
        self.assertAlmostEqual(stages["encode"]["share_of_full_p50"], 0.6, places=12)
        outside = {item["stage"]: item for item in group["outside_full"]}
        self.assertEqual(list(outside), outside_names)
        for item in outside.values():
            self.assertEqual(item["scope"], "outside_full")
            self.assertEqual(item["share_rows"], 0)
            self.assertIsNone(item["share_of_full_p50"])
            self.assertIsNone(item["share_of_total_full"])
        self.assertEqual(outside["cleanup"]["p50_us"], 2.0)
        consistency = group["consistency"]
        self.assertEqual(consistency["over_full"]["count"], 0)
        self.assertEqual(consistency["coverage"], {"min": 0.9, "p50": 0.9, "max": 0.9})
        self.assertTrue(consistency["consistent"])
        self.assertNotIn("stage_overcount", warning_codes(report))
        markdown = ps.render_markdown(report)
        self.assertIn("### Outside full", markdown)
        self.assertIn("never added to or subtracted from full", markdown)
        self.assertEqual(ps.render_markdown(json.loads(ps.to_json(report))), markdown)

    def test_part_selection_is_validated(self):
        for parts, pattern in (
            (["mel", "nope"], "has no stage nope"),
            (["mel", "full"], "'full' is not a part"),
            (["mel", "mel"], "listed twice"),
            (["(unattributed)"], "not a part"),
            ([""], "non-empty stage names"),
        ):
            with self.subTest(str(parts)), self.assertRaisesRegex(ps.InputError, pattern):
                self.report(ledger_rows(), stage_parts=parts)

    def test_parts_need_stage_profile_and_a_full_stage(self):
        path = self.write_jsonl("timing.jsonl", grid_rows())
        with self.assertRaisesRegex(ps.InputError, "needs --stage-profile"):
            ps.analyze([path], pairs=["base:cand"], stage_parts=["mel"])
        stages = {"mel": 1, "encode": 2}
        rows = [{"type": "stage_profile", "row_id": "s0", "pass": 1, "audio_s": 1.0, "stages_us": stages}]
        with self.assertRaisesRegex(ps.InputError, "no 'full' stage"):
            self.report(rows, stage_parts=["mel"])

    def test_a_sample_missing_a_selected_part_is_flagged(self):
        rows = ledger_rows()
        for row in rows:
            if row["type"] == "stage_profile" and row["row_id"] == "s3" and row["pass"] == 2:
                del row["stages_us"]["tail"]
        report = self.report(rows, stage_parts=["mel", "encode", "tail"])
        consistency = report["stage_profile"]["groups"][0]["consistency"]
        self.assertIn("stage_missing_part", warning_codes(report))
        self.assertEqual(consistency["samples_missing_part"], 1)
        self.assertFalse(consistency["consistent"])

    def test_ledger_grid_is_checked(self):
        report = self.report(ledger_rows())
        integrity = report["integrity"][0]
        self.assertEqual((integrity["status"], integrity["grid"]["expected_cells"]), ("grid_only", 12))
        self.assertIn("incomplete_provenance", warning_codes(report))
        self.assertIn("ignored_rows", warning_codes(report))
        cut = [
            row
            for row in ledger_rows()
            if not (row["type"] == "stage_profile" and row["row_id"] == "s3" and row["pass"] == 2)
        ]
        with self.assertRaisesRegex(ps.InputError, r"incomplete grid: 11 of 12 declared cells written"):
            self.report(cut)

    def test_cli_stage_parts(self):
        path = self.write_jsonl("ledger.jsonl", ledger_rows())
        out_json = self.tmp / "ledger.json"
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = ps.main([path, "--stage-profile", "--stage-parts", "mel, encode ,tail", "--json", str(out_json)])
            self.assertEqual(ps.main([path, "--stage-profile", "--stage-parts", "mel,,tail"]), 2)
        self.assertEqual(code, 0)
        report = json.loads(out_json.read_text(encoding="utf-8"))
        self.assertEqual(report["settings"]["stage_parts"], ["mel", "encode", "tail"])
        self.assertIn("### Outside full", stdout.getvalue())


class CommandLineTests(TempDirTestCase):
    def test_writes_json_and_markdown(self):
        levels = paired_levels(pairs=20)
        factors = {
            "ggml": dict.fromkeys(levels, 1.0),
            "ggml@aa": alternating(levels, 0.98, 1.02),
            "rust": dict.fromkeys(levels, 0.75),
        }
        path = self.write_jsonl("cli.jsonl", interleaved_rows(levels, factors))
        out_json = self.tmp / "out" / "report.json"
        out_md = self.tmp / "out" / "report.md"
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = ps.main(
                [path, "--all-vs", "ggml", "--bootstrap", "500", "--json", str(out_json), "--md", str(out_md)]
            )
        self.assertEqual(code, 0)
        report = json.loads(out_json.read_text(encoding="utf-8"))
        self.assertEqual(report["settings"]["seed"], ps.DEFAULT_SEED)
        self.assertEqual([pair["label"] for pair in report["timing"]["pairs"]], ["ggml vs rust", "ggml vs ggml@aa"])
        markdown = out_md.read_text(encoding="utf-8")
        headings = ("## Inputs", "## Arms", "## Pairs: speed", "## Pairs: tests and savings", "## Equivalence")
        for heading in (*headings, "## Drift"):
            self.assertIn(heading, markdown)
        self.assertIn("| ggml | rust | 40 | 0.7500 |", markdown)
        self.assertEqual(markdown, ps.render_markdown(report))

    def test_errors_exit_with_status_two(self):
        path = self.write_jsonl("err.jsonl", [timing_row("a", 1, 1, 1, 10.0)])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(ps.main([path, "--pair", "a:missing"]), 2)
            self.assertEqual(ps.main([path]), 2)
            with self.assertRaises(SystemExit):
                ps.main([path, "--pair", "a:b", "--all-vs", "a"])
        self.assertIn("unknown arm", stderr.getvalue())

    def test_bad_json_reports_location(self):
        path = self.tmp / "broken.jsonl"
        path.write_text(json.dumps(timing_row("a", 1, 1, 1, 10.0)) + "\n{not json\n", encoding="utf-8")
        with self.assertRaises(ps.InputError) as caught:
            ps.analyze([str(path)], pairs=["a:a"])
        self.assertIn("broken.jsonl:2", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
