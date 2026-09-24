"""Coverage regressions from the review of the robust estimator.

Both nulls come from the GPT-6 Astra review. The analyze-level tests fail on the
rejected estimator (outlier rounds removed from intervals, two-sample intervals for
implementations of one process) and pass on the current one.
"""

import itertools
import json
import math
from collections import Counter
from pathlib import Path

import pytest

from fastmem_bench.analysis import analyze, compare_independent, compare_paired
from tests.conftest import measurement

# Independent null with a minority mode: every round draws one log value uniformly.
MODES = (-0.005, 0.0, 0.005, 0.295, 0.3, 0.305)
# Dependent null: candidate exp(z), reference exp(-z), z uniform per process.
FACTORS = (-0.024, -0.012, -0.001, 0.001, 0.012, 0.024)


def write_rounds(root: Path, variant: str, factors: dict[str, list[float]]) -> None:
    """Write 5 rounds of the fixture case. factors[impl][round] scales that impl."""
    for index in range(5):
        path = root / variant / f"r{index}.jsonl"
        measurement(path)
        records = [json.loads(line) for line in path.read_text().splitlines()]
        for record in records:
            if record["type"] == "sample" and record["impl"] in factors:
                record["ns"] = round(1_000_000 * factors[record["impl"]][index])
        path.write_text("\n".join(json.dumps(record) for record in records) + "\n")


def row_for(result: dict, comparison: str, impl: str) -> dict:
    return next(
        row
        for row in result["rows"]
        if row["comparison"] == comparison and row["candidate_impl"] == impl
    )


def misses(interval: list[float]) -> bool:
    return interval[0] > 1 or interval[1] < 1


def test_flagged_rounds_stay_in_the_aa_interval(tmp_path: Path) -> None:
    # One round of each variant is in the other mode: a legitimate draw of the null.
    high, low = math.exp(0.3), 1.0
    write_rounds(tmp_path, "v0", {"builtin": [high, high, high, high, low]})
    write_rounds(tmp_path, "aa", {"builtin": [low, low, low, low, high]})
    result = analyze(tmp_path, ["v0"], "v0")
    row = row_for(result, "A/A", "builtin")
    assert row["outlier_rounds"] == {"candidate": [4], "baseline": [4]}
    # The rejected estimator removed both flagged rounds: [0.741, 0.741], which misses 1.
    assert not misses(row["ci95"])
    assert row["ci_method"] == "mann-whitney"
    assert row["ci_level"] == pytest.approx(1 - 8 / 252)


def test_same_process_implementations_use_a_paired_interval(tmp_path: Path) -> None:
    z = [0.024, 0.024, 0.024, 0.024, -0.001]
    factors = {
        "builtin": [math.exp(value) for value in z],
        "glibc": [math.exp(-value) for value in z],
    }
    write_rounds(tmp_path, "v0", factors)
    write_rounds(tmp_path, "aa", factors)
    result = analyze(tmp_path, ["v0"], "v0")
    row = row_for(result, "builtin/glibc", "builtin")
    # The rejected two-sample interval was [1.023, 1.049], which misses 1.
    assert not misses(row["ci95"])
    assert row["ci_method"] == "signed-rank"
    assert row["ci_level"] == pytest.approx(0.9375)
    assert not row["significant"]
    aa = row_for(result, "A/A", "builtin")
    assert aa["ci_method"] == "mann-whitney"


def weighted_multisets(values: tuple[float, ...], size: int) -> list[tuple[list[float], int]]:
    """Every multiset of `size` draws, with the number of ordered draws that give it."""
    out = []
    for combination in itertools.combinations_with_replacement(values, size):
        weight = math.factorial(size)
        for count in Counter(combination).values():
            weight //= math.factorial(count)
        out.append(([math.exp(value) for value in combination], weight))
    return out


def test_independent_interval_coverage_on_the_mode_null() -> None:
    samples = weighted_multisets(MODES, 5)
    total = missed = 0
    for (left, left_weight), (right, right_weight) in itertools.product(samples, repeat=2):
        weight = left_weight * right_weight
        total += weight
        missed += weight * misses(compare_independent(left, right)["ci95"])
    assert total == 6**10
    # The review measured 1.408% unfiltered and 8.482% after outlier removal.
    assert missed / total == pytest.approx(0.01408, abs=5e-5)
    assert missed / total <= 1 - compare_independent([1] * 5, [1] * 5)["ci_level"]


def test_paired_interval_coverage_on_the_dependent_null() -> None:
    paired = independent = 0
    assignments = list(itertools.product(FACTORS, repeat=5))
    for z in assignments:
        candidate = [math.exp(value) for value in z]
        reference = [math.exp(-value) for value in z]
        paired += misses(compare_paired(candidate, reference)["ci95"])
        independent += misses(compare_independent(candidate, reference)["ci95"])
    assert len(assignments) == 7776
    # The range of 5 per-round ratios misses 1 when all 5 signs agree: 2/32.
    assert paired / len(assignments) == pytest.approx(1 - 0.9375)
    # The two-sample interval claims 96.8% here but misses 8.4% (656 of 7776).
    assert independent == 656
