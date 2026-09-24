import json
from collections import Counter
from itertools import pairwise
from pathlib import Path

import pytest
from click.testing import CliRunner

from fastmem_bench.analysis import analyze
from fastmem_bench.protocol import orders
from fastmem_bench.runner import analyze_run
from tests.conftest import measurement


def write_cases(path: Path, cases: list[tuple[str, int, str, float]], *, jitter: float = 0) -> None:
    """Write cases with optional libc-only A/A noise."""
    records = []
    for profile, size, op, scale in cases:
        measurement(path, scale, size=size)
        raw = [json.loads(line) for line in path.read_text().splitlines()]
        if not records:
            records.append(raw[0])
        for row in raw[1:-1]:
            row.update(case=f"{op}/{profile}/{size}", profile=profile, op=op)
            if profile == "dist" or op == "move":
                row.update(src_off=None, dst_off=None)
            if row["impl"] == "libc":
                row["ns"] *= 1 + jitter
            records.append(row)
    records.append({"type": "end", "cases": len(cases), "elapsed_ns": 1})
    path.write_text("\n".join(json.dumps(row) for row in records) + "\n")


def test_floors_pool_profiles_and_impls_and_include_ci(tmp_path: Path) -> None:
    cases = [
        ("aligned", 32, "copy", 1.0),
        ("cross-lane", 32, "copy", 1.0),
        ("aligned", 4096, "copy", 1.0),
    ]
    for index in range(5):
        write_cases(tmp_path / "v0" / f"r{index}.jsonl", cases)
        aa_cases = [cases[0], ("cross-lane", 32, "copy", 1.1 if index == 0 else 1.0), cases[2]]
        write_cases(tmp_path / "aa" / f"r{index}.jsonl", aa_cases, jitter=0.02)
    result = analyze(tmp_path, ["v0"], "v0")
    assert result["noise_floors"]["copy/size/32"] == pytest.approx(0.122)
    assert result["noise_floors"]["copy/size/4096"] == pytest.approx(0.02)
    aa_rows = [row for row in result["rows"] if row["comparison"] == "A/A"]
    assert {row["candidate_impl"] for row in aa_rows} == {"fastmem", "builtin", "libc"}
    assert max(abs(row["ratio"] - 1) for row in aa_rows) < result["noise_floors"]["copy/size/32"]
    assert all(
        row["noise_floor"] == result["noise_floors"][row["floor_group"]] for row in result["rows"]
    )


def test_dist_floor_uses_op_tier(tmp_path: Path) -> None:
    for index in range(5):
        for variant in ("v0", "aa"):
            cases = [
                ("dist", 31, "copy", 1.0),
                ("dist", 48, "copy", 1.05 if variant == "aa" else 1.0),
                ("dist", 48, "move", 1.0),
            ]
            write_cases(tmp_path / variant / f"r{index}.jsonl", cases)
    result = analyze(tmp_path, ["v0"], "v0")
    assert result["noise_floors"] == pytest.approx({"copy/tier/17-64": 0.05, "move/tier/17-64": 0})


@pytest.mark.parametrize("rounds", [1, 2, 3, 4, 5])
def test_round_threshold_and_minimum_effect(tmp_path: Path, rounds: int) -> None:
    for index in range(rounds):
        measurement(tmp_path / "v0" / f"r{index}.jsonl")
        measurement(tmp_path / "aa" / f"r{index}.jsonl")
    result = analyze(tmp_path, ["v0"], "v0")
    assert any(row["significant"] for row in result["rows"]) == (rounds >= 5)
    conservative = analyze(tmp_path, ["v0"], "v0", minimum_effect=0.6)
    assert not any(row["significant"] for row in conservative["rows"])


def test_intersect_revisions_with_warning(tmp_path: Path) -> None:
    common = [("aligned", 64, "copy", 1.0)]
    for index in range(5):
        for variant in ("v0", "aa", "v1"):
            cases = common + ([("aligned", 32, "copy", 1.0)] if variant == "v1" else [])
            write_cases(tmp_path / variant / f"r{index}.jsonl", cases)
    result = analyze(tmp_path, ["v0", "v1"], "v0")
    assert {row["case"] for row in result["rows"]} == {"copy/aligned/64"}
    assert "v1: excluded 3 unmatched" in result["warnings"][0]


def test_inconsistent_cases_within_revision_fail(tmp_path: Path) -> None:
    measurement(tmp_path / "v0/r0.jsonl", size=32)
    measurement(tmp_path / "v0/r1.jsonl", size=64)
    with pytest.raises(ValueError, match="within v0"):
        analyze(tmp_path, ["v0"], "v0", aa=None)


@pytest.mark.parametrize("count", [1, 2, 3, 4, 5, 6])
def test_balanced_latin_square(count: int) -> None:
    variants = [f"v{index}" for index in range(count)]
    block_size = count * (2 if count > 1 and count % 2 else 1)
    schedule = orders(variants, 2 * block_size, 99)
    assert schedule == orders(variants, 2 * block_size, 99)
    for start in range(0, len(schedule), count):
        for column in zip(*schedule[start : start + count], strict=True):
            assert set(column) == set(variants)
    for start in range(0, len(schedule), block_size):
        predecessors = Counter(
            (left, right)
            for row in schedule[start : start + block_size]
            for left, right in pairwise(row)
        )
        assert len(set(predecessors.values())) <= 1
        assert len(predecessors) == count * (count - 1)


def test_offline_analysis_and_incomplete_run(tmp_path: Path) -> None:
    manifest = {
        "run_id": "test",
        "sources": [{"variant": "v0", "revision": "WORKTREE"}],
        "aa": True,
        "rounds": 5,
        "targets": ["intel"],
    }
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / "intel/raw" / variant / f"r{index}.jsonl")
    result = CliRunner().invoke(analyze_run, [str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert "intel copy/size/64: 0.0000%" in result.output
    assert (tmp_path / "report.md").exists()
    for variant in ("v0", "aa"):
        (tmp_path / "intel/raw" / variant / "r4.jsonl").unlink()
    result = CliRunner().invoke(analyze_run, [str(tmp_path)])
    assert result.exit_code == 1
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert "Incomplete round set" in summary["targets"]["intel"]["error"]
