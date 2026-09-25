"""Runtime-dispatch evidence of G6 x86_64 builds (docs/runtime-dispatch.md)."""

from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.analysis import analyze
from fastmem_bench.build import expected_dispatch
from fastmem_bench.jsonl import parse
from fastmem_bench.report import dispatch_lines
from tests.conftest import PROBE, measurement

SPR: dict[str, Any] = {
    "level": "sapphirerapids",
    "kernel": "x86-avx512-straight_1k-v3",
    "vendor": "intel",
    "family": 6,
    "model": 143,
}


def test_expected_level_is_the_target_model_of_a_baseline_x86_build() -> None:
    intel = {
        "zig_target": "x86_64-linux-gnu",
        "zig_cpu": "sapphirerapids",
        "baseline_cpu": "x86_64",
    }
    assert expected_dispatch(intel, "baseline") == "sapphirerapids"
    assert expected_dispatch(intel, "target") is None
    assert expected_dispatch({**intel, "baseline_cpu": "x86_64_v3"}, "baseline") is None
    assert expected_dispatch({**intel, "zig_cpu": "skylake"}, "baseline") is None
    arm = {"zig_target": "aarch64-linux-gnu", "zig_cpu": "neoverse_v2"}
    assert expected_dispatch(arm, "baseline") is None


def test_meta_accepts_dispatch_and_rejects_bad_records(tmp_path: Path) -> None:
    measurement(tmp_path / "ok.jsonl", cpu="x86_64", dispatch=SPR)
    assert parse(tmp_path / "ok.jsonl").meta["dispatch"] == SPR
    measurement(tmp_path / "none.jsonl")
    assert parse(tmp_path / "none.jsonl").meta["dispatch"] is None
    measurement(tmp_path / "bad.jsonl", dispatch={**SPR, "level": "haswell"})
    with pytest.raises(ValueError, match="level"):
        parse(tmp_path / "bad.jsonl")


def test_analysis_checks_the_dispatched_level(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl", cpu="x86_64", dispatch=SPR)
    result = analyze(
        tmp_path, ["v0"], "v0", probe=PROBE, cpu_mode="baseline", expected_dispatch="sapphirerapids"
    )
    assert result["dispatch"] == {"v0": SPR, "aa": SPR}
    with pytest.raises(ValueError, match="dispatched level is sapphirerapids, not x86_64_v4"):
        analyze(
            tmp_path, ["v0"], "v0", probe=PROBE, cpu_mode="baseline", expected_dispatch="x86_64_v4"
        )
    # One process with a different level: the variant is not one binary state.
    measurement(tmp_path / "v0/r4.jsonl", cpu="x86_64", dispatch={**SPR, "level": "x86_64_v4"})
    with pytest.raises(ValueError, match="changed within v0"):
        analyze(tmp_path, ["v0"], "v0", probe=PROBE, cpu_mode="baseline")


def test_pre_dispatch_revisions_still_analyze(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl", cpu="x86_64")
    result = analyze(
        tmp_path, ["v0"], "v0", probe=PROBE, cpu_mode="baseline", expected_dispatch="sapphirerapids"
    )
    assert result["dispatch"] == {"v0": None, "aa": None}


def test_report_names_the_dispatched_level() -> None:
    kernel = "sapphirerapids (x86-avx512-straight_1k-v3)"
    line = f"Runtime dispatch, v0: {kernel}, intel family 6 model 143."
    assert dispatch_lines({"v0": SPR, "aa": None}) == [line, ""]
    assert dispatch_lines({}) == []
