import copy
import json
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.analysis import analyze
from fastmem_bench.build import baseline_cpu, build_cpu
from fastmem_bench.stability import binary_groups, memory_summary, memory_warning, spike_group
from tests.conftest import CODEGEN, MEMORY, PROBE, measurement


def test_spike_group_pools_the_variants_of_one_binary() -> None:
    cells: Any = {
        ("v0", "copy/aligned/64", "builtin"): ([1.0, 1.0, 1.0, 1.0, 1.5], []),
        ("aa", "copy/aligned/64", "builtin"): ([1.0, 1.05, 1.0, 1.0, 1.0], []),
        ("v0", "copy/aligned/8", "builtin"): ([1.0, 1.0, 1.0, 1.2, 1.0], []),
        ("aa", "copy/aligned/8", "builtin"): ([1.0, 1.0, 1.0, 1.0, 1.0], []),
    }
    group = spike_group(cells, ["v0", "aa"])
    assert group["round_cells"] == 20
    assert group["spikes"] == 2
    assert group["by_variant"] == {"v0": 2, "aa": 0}
    assert group["by_process"] == {"v0/r3": 1, "v0/r4": 1}
    assert group["worst_process_share"] == 0.5


def test_binary_groups_follow_the_executable_digest() -> None:
    other = {**CODEGEN, "binary_sha256": "1" * 64}
    codegen = {"v0": CODEGEN, "v1": other, "v2": other, "aa": CODEGEN}
    assert binary_groups(["v0", "v1", "v2", "aa"], codegen, "v0", "aa") == [
        ["v0", "aa"],
        ["v1", "v2"],
    ]
    # Without evidence, only the A/A variant is known to share the baseline binary.
    empty = dict.fromkeys(["v0", "v1", "aa"])
    assert binary_groups(["v0", "v1", "aa"], empty, "v0", "aa") == [["v0", "aa"], ["v1"]]


def test_memory_summary_reports_partial_thp() -> None:
    partial = {**MEMORY, "anon_huge_bytes_start": 2 << 20, "anon_huge_bytes_end": 4 << 20}
    summary = memory_summary({"v0/r0": MEMORY, "v0/r1": partial, "aa/r0": None})
    assert summary["processes"] == 3
    assert summary["arena_processes"] == 2
    assert summary["thp_full_processes"] == 1
    assert summary["thp_changed_processes"] == ["v0/r1"]
    assert summary["thp_coverage_min"] == pytest.approx(1 / 3)
    assert "1 of 2 processes" in (memory_warning(summary) or "")
    assert memory_warning(memory_summary({"v0/r0": MEMORY})) is None
    assert memory_warning(memory_summary({"v0/r0": None})) is None


def test_analysis_reports_stability_memory_and_cpu(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl", scale=1.3 if index == 4 else 1)
    result = analyze(tmp_path, ["v0"], "v0", probe=PROBE)
    (group,) = result["stability"]["groups"]
    assert group["variants"] == ["v0", "aa"]
    # Every implementation of the case spikes in round 4 of both processes.
    assert group["ns"]["spikes"] == 8
    assert group["ns"]["by_process"] == {"aa/r4": 4, "v0/r4": 4}
    assert group["ns"]["null_floor"]["groups"] == 1
    # The fixture has no perf counts, so the cycles metric has no cells.
    assert group["cycles"]["round_cells"] == 0
    assert group["cycles"]["null_floor"] is None
    assert result["memory"]["thp_full_processes"] == 10
    assert result["cpu"] == {"mode": "target", "models": ["sapphirerapids"]}
    with pytest.raises(ValueError, match="not x86_64_v3"):
        analyze(tmp_path, ["v0"], "v0", probe=PROBE, expected_cpu="x86_64_v3")


def test_old_schema_rounds_still_analyze(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl", schema=2)
    result = analyze(tmp_path, ["v0"], "v0", probe=PROBE)
    assert result["memory"]["arena_processes"] == 0
    assert not any("THP" in warning for warning in result["warnings"])
    assert result["goals"][0]["G6"]["status"] == "NA"


def test_baseline_cpu_comes_from_bench_toml_or_the_arch() -> None:
    x86 = {"arch": "x86_64", "zig_target": "x86_64-linux-gnu", "zig_cpu": "znver5"}
    arm = {"arch": "arm64", "zig_target": "aarch64-linux-gnu", "zig_cpu": "neoverse_v2"}
    assert baseline_cpu(x86) == "x86_64"
    assert baseline_cpu(arm) == "generic"
    assert baseline_cpu({**arm, "baseline_cpu": "neoverse_n1"}) == "neoverse_n1"
    assert build_cpu(x86, "target") == "znver5"
    assert build_cpu(x86, "baseline") == "x86_64"
    with pytest.raises(ValueError, match="baseline_cpu"):
        baseline_cpu({**arm, "baseline_cpu": "native"})
    with pytest.raises(ValueError, match="Unknown CPU mode"):
        build_cpu(x86, "native")
    with pytest.raises(ValueError, match="explicit CPU"):
        build_cpu({**x86, "zig_cpu": "native"}, "target")


def test_bench_toml_baseline_cpus() -> None:
    import tomllib

    targets = tomllib.loads((Path(__file__).parents[2] / "bench.toml").read_text())["targets"]
    for settings in targets.values():
        expected = "x86_64" if settings["arch"] == "x86_64" else "generic"
        assert settings["baseline_cpu"] == expected


def test_report_renders_g6_and_stability(tmp_path: Path) -> None:
    from fastmem_bench.report import write

    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / "raw" / variant / f"r{index}.jsonl", cpu="x86_64_v3")
    result = analyze(tmp_path / "raw", ["v0"], "v0", probe=PROBE, cpu_mode="baseline")
    write(tmp_path, {"variants": {"v0": "WORKTREE"}, "targets": {"intel": result}})
    report = (tmp_path / "report.md").read_text()
    assert "| v0 | copy | G6 | NA |" in report
    assert "### Measurement stability" in report
    assert "THP covered the whole arena in 10" in report
    summary = json.loads((tmp_path / "summary.json").read_text())
    goal = summary["targets"]["intel"]["goals"][0]
    assert goal["G2"]["reason"].startswith("G2-G4 require the bench.toml zig_cpu build")
    assert copy.deepcopy(goal["G6"])["rule"] == "lower > 1 + max(floor, 0.01)"


def test_cycles_metric_uses_only_fully_counted_samples(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            path = tmp_path / variant / f"r{index}.jsonl"
            measurement(path)
            records = [json.loads(line) for line in path.read_text().splitlines()]
            records[0]["perf"] = {
                "available": True,
                "events": ["cycles", "instructions"],
                "error": None,
            }
            for row in records[1:-1]:
                # Round 2 of v0 runs at twice the cycles for the same instructions.
                cycles = 200000 if (variant, index) == ("v0", 2) else 100000
                row.update(
                    cycles=cycles,
                    instructions=50000,
                    time_enabled=1000,
                    time_running=1000,
                )
            path.write_text("\n".join(json.dumps(record) for record in records) + "\n")
    group = analyze(tmp_path, ["v0"], "v0", probe=PROBE)["stability"]["groups"][0]
    assert group["cycles"]["spikes"] == 4
    assert group["cycles"]["by_process"] == {"v0/r2": 4}
    assert group["ns"]["spikes"] == 0
    # A multiplexed sample leaves the cycles metric, so the round has no cycles cell.
    path = tmp_path / "aa/r3.jsonl"
    records = [json.loads(line) for line in path.read_text().splitlines()]
    for row in records[1:-1]:
        row["time_running"] = 500
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n")
    group = analyze(tmp_path, ["v0"], "v0", probe=PROBE)["stability"]["groups"][0]
    assert group["cycles"]["round_cells"] == 0
