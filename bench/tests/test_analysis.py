import json
from pathlib import Path

import pytest

from fastmem_bench.analysis import (
    analyze,
    compare_independent,
    compare_paired,
    geomean,
    hodges_lehmann,
    outlier_rounds,
    quantile,
    rank_interval,
    round_medians,
    signed_rank_interval,
    significant,
    tier,
)
from fastmem_bench.jsonl import parse
from fastmem_bench.protocol import orders
from tests.conftest import measurement


def test_orders() -> None:
    variants = ["v0", "v1", "aa"]
    left = orders(variants, 5, 1234)
    assert left == orders(variants, 5, 1234)
    assert left != orders(variants, 5, 4321)
    assert variants == ["v0", "v1", "aa"]
    assert all(sorted(order) == sorted(variants) for order in left)


def test_schema(tmp_path: Path) -> None:
    path = tmp_path / "round.jsonl"
    measurement(path)
    parsed = parse(path)
    assert parsed.meta["schema"] == 3
    measurement(path, schema=2)
    assert parse(path).meta["schema"] == 2
    assert parsed.samples[0]["ns"] / parsed.samples[0]["iters"] == 20
    path.write_text("\n".join(path.read_text().splitlines()[:-1]))
    with pytest.raises(ValueError, match="no end record"):
        parse(path)


@pytest.mark.parametrize("mutation", ["schema", "cases", "iters", "duplicate"])
def test_reject_invalid(tmp_path: Path, mutation: str) -> None:
    path = tmp_path / "round.jsonl"
    measurement(path)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    if mutation == "schema":
        records[0]["schema"] = 1
    elif mutation == "cases":
        records[-1]["cases"] = 2
    elif mutation == "iters":
        records[1]["iters"] = 0
    else:
        records.insert(1, records[1])
    path.write_text("\n".join(json.dumps(record) for record in records))
    with pytest.raises(ValueError, match=str(path)):
        parse(path)


def test_math() -> None:
    assert round_medians([[8, 9, 30], [9, 10]]) == [9, 9.5]
    assert hodges_lehmann([1, 2], [0]) == 1.5
    assert compare_independent([2], [4]) == {
        "ratio": 0.5,
        "ci95": [0.5, 0.5],
        "ci_level": 0,
        "ci_method": "mann-whitney",
    }
    assert compare_paired([2], [4]) == {
        "ratio": 0.5,
        "ci95": [0.5, 0.5],
        "ci_level": 0,
        "ci_method": "signed-rank",
    }
    # Walsh averages of the per-round log ratios log 2, log 4, log 8: the estimate is log 4.
    paired = compare_paired([2, 4, 8], [1, 1, 1])
    assert paired["ratio"] == pytest.approx(4)
    assert paired["ci95"] == pytest.approx([2, 8])
    assert paired["ci_level"] == pytest.approx(0.75)
    with pytest.raises(ValueError, match="matched"):
        compare_paired([1, 2], [1])
    assert geomean([0.5, 2]) == pytest.approx(1)
    assert quantile([0, 1, 2, 3, 4], 0.95) == pytest.approx(3.8)
    assert quantile([7], 0.95) == 7
    assert significant((0.88, 0.92), 0.02)
    assert significant((1.03, 1.2), 0.02)
    assert not significant((0.98, 0.999), 0.02)
    assert not significant((0.8, 1.01), 0.02)
    # The point is above the floor, but the interval reaches into the floor band.
    assert not significant((1.01, 1.2), 0.02)
    assert not significant((0.88, 0.92), None)
    # The band is symmetric on the log scale: 1 / 1.05 and 1.05 are equally far from 1.
    assert significant((0.9, 0.95), 0.05)
    assert not significant((0.9, 0.97), 0.05)


@pytest.mark.parametrize(
    ("rounds", "k", "coverage"),
    [
        ((1, 1), 1, 0),
        ((3, 3), 1, 0.9),
        ((4, 4), 1, 1 - 2 / 70),
        ((4, 5), 2, 1 - 4 / 126),
        ((5, 5), 3, 1 - 8 / 252),
    ],
)
def test_rank_interval(rounds: tuple[int, int], k: int, coverage: float) -> None:
    assert rank_interval(*rounds) == (k, pytest.approx(coverage))


def test_outlier_rounds() -> None:
    assert outlier_rounds([1.0, 1.001, 0.999, 4.7, 1.0]) == [3]
    assert outlier_rounds([1.0, 1.0, 1.0, 1.0, 0.63]) == [4]
    # Below both the robust spread test and the 5% materiality guard.
    assert outlier_rounds([1.0, 1.0, 1.0, 1.0, 1.04]) == []
    # Two departing rounds describe a multimodal cell, not a spike.
    assert outlier_rounds([1.0, 1.0, 4.0, 4.0, 1.0]) == []
    assert outlier_rounds([1.0, 1.0, 1.0, 4.7]) == []


@pytest.mark.parametrize(
    ("rounds", "k", "coverage"),
    [
        (1, 1, 0),
        (3, 1, 0.75),
        (5, 1, 0.9375),
        (6, 1, 1 - 2 / 64),
        (7, 3, 1 - 6 / 128),
        (8, 4, 1 - 10 / 256),
    ],
)
def test_signed_rank_interval(rounds: int, k: int, coverage: float) -> None:
    assert signed_rank_interval(rounds) == (k, pytest.approx(coverage))


def test_spiky_round_stays_in_ratio_and_interval() -> None:
    clean = [1.00, 1.01, 0.99, 1.02, 1.00]
    spiky = [1.00, 1.01, 4.73, 1.02, 1.00]
    baseline = [1.0, 1.0, 1.01, 0.99, 1.0]
    assert outlier_rounds(spiky) == [2]
    reference = compare_independent(clean, baseline)
    estimate = compare_independent(spiky, baseline)
    assert estimate["ratio"] == pytest.approx(reference["ratio"], abs=0.011)
    # The flag is a report. The interval keeps the spike on its side.
    assert estimate["ci95"][1] > 4
    assert estimate["ci_level"] == pytest.approx(1 - 8 / 252)


@pytest.mark.parametrize(
    ("size", "expected"),
    [
        (0, "0-16"),
        (16, "0-16"),
        (17, "17-64"),
        (64, "17-64"),
        (65, "65-256"),
        (256, "65-256"),
        (257, "257-1024"),
        (1024, "257-1024"),
        (1025, "1025-16384"),
        (16384, "1025-16384"),
        (16385, ">16384"),
    ],
)
def test_tiers(size: int, expected: str) -> None:
    assert tier(size) == expected


def test_analysis(tmp_path: Path) -> None:
    for variant, scale in (("v0", 1), ("v1", 0.8), ("aa", 1.01)):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl", scale)
    result = analyze(tmp_path, ["v0", "v1"], "v0")
    assert result["noise_floors"]["copy/size/64"] == pytest.approx(0.01)
    revision = next(row for row in result["rows"] if row["comparison"] == "revision")
    assert revision["ratio"] == pytest.approx(0.8)
    assert revision["significant"]
    assert revision["candidate_ns"] == 8
    assert next(row for row in result["tiers"] if row["comparison"] == "revision")[
        "geomean"
    ] == pytest.approx(0.8)
    no_aa = analyze(tmp_path, ["v0", "v1"], "v0", aa=None)
    assert no_aa["noise_floors"] == {}
    assert not any(row["significant"] for row in no_aa["rows"])


def test_mismatched_rounds(tmp_path: Path) -> None:
    measurement(tmp_path / "v0/r0.jsonl")
    measurement(tmp_path / "aa/r1.jsonl")
    with pytest.raises(ValueError, match="different round sets"):
        analyze(tmp_path, ["v0"], "v0")
