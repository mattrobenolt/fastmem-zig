import json
from pathlib import Path

import pytest

from fastmem_bench.analysis import analyze, bootstrap, geomean, ratio, significant, tier
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
    assert parsed.meta["schema"] == 1
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
        records[0]["schema"] = 2
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
    candidate: list[list[float]] = [[8, 9], [9, 10], [10, 11]]
    baseline: list[list[float]] = [[10, 11], [11, 12], [12, 13]]
    assert ratio(candidate, baseline) == pytest.approx(9.5 / 11.5)
    assert bootstrap(candidate, baseline) == bootstrap(candidate, baseline)
    assert bootstrap([[2]], [[4]]) == (0.5, 0.5)
    assert geomean([0.5, 2]) == pytest.approx(1)
    assert significant(0.9, (0.88, 0.92), 0.02)
    assert not significant(0.99, (0.98, 0.999), 0.02)
    assert not significant(0.9, (0.8, 1.01), 0.02)
    assert not significant(0.9, (0.88, 0.92), None)


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
        for index in range(3):
            measurement(tmp_path / variant / f"r{index}.jsonl", scale)
    result = analyze(tmp_path, ["v0", "v1"], "v0")
    assert result["noise_floor"] == pytest.approx(0.01)
    revision = next(row for row in result["rows"] if row["comparison"] == "revision")
    assert revision["ratio"] == pytest.approx(0.8)
    assert revision["significant"]
    assert revision["candidate_ns"] == 8
    assert next(row for row in result["tiers"] if row["comparison"] == "revision")[
        "geomean"
    ] == pytest.approx(0.8)
    no_aa = analyze(tmp_path, ["v0", "v1"], "v0", aa=None)
    assert no_aa["noise_floor"] is None
    assert not any(row["significant"] for row in no_aa["rows"])


def test_mismatched_rounds(tmp_path: Path) -> None:
    measurement(tmp_path / "v0/r0.jsonl")
    measurement(tmp_path / "aa/r1.jsonl")
    with pytest.raises(ValueError, match="different round sets"):
        analyze(tmp_path, ["v0"], "v0")
