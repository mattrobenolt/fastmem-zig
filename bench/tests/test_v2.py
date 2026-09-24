import copy
import json
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.analysis import analyze
from fastmem_bench.goals import CONST_SIZES, required_cases
from fastmem_bench.goals import evaluate as evaluate_goals
from fastmem_bench.jsonl import parse, parse_text, verify_probe
from tests.conftest import CODEGEN, PROBE, measurement
from tests.test_protocol import FakeBox, setup


def evaluate(rows: list[dict[str, Any]], variants: list[str]) -> list[dict[str, Any]]:
    return evaluate_goals(rows, variants, codegen=dict.fromkeys(variants, CODEGEN))


def test_v2_resolution_and_probe(tmp_path: Path) -> None:
    path = tmp_path / "round.jsonl"
    measurement(path)
    actual = parse(path, probe=PROBE)
    for symbol in ("memcpy", "memmove", "memset"):
        probe = copy.deepcopy(PROBE)
        probe["symbols"][symbol]["offset"] = "0xdead"
        with pytest.raises(ValueError, match=f"{symbol} offset disagrees"):
            verify_probe(actual, probe)
    probe = {**PROBE, "libc_path": "/wrong/libc.so.6"}
    with pytest.raises(ValueError, match="libc path disagrees"):
        verify_probe(actual, probe)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    records[0]["resolution"]["memcpy"]["builtin"] = records[0]["resolution"]["memcpy"]["glibc"]
    with pytest.raises(ValueError, match="Invalid glibc/builtin resolution"):
        parse_text("\n".join(json.dumps(record) for record in records))


@pytest.mark.parametrize("profile", ["aligned", "const"])
def test_per_case_implementation_applicability(tmp_path: Path, profile: str) -> None:
    path = tmp_path / "round.jsonl"
    measurement(path)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    meta, end = records[0], records[-1]
    meta["suite"] = "standard"
    meta["impls"].append("builtin_const")
    op = "set" if profile == "aligned" else "copy"
    samples = []
    for row in records[1:-1]:
        if profile == "const":
            if row["impl"] not in {"builtin", "fastmem_inline"}:
                continue
            if row["impl"] == "builtin":
                row["impl"] = "builtin_const"
        elif row["impl"] not in {"builtin", "glibc"}:
            continue
        row.update(op=op, profile=profile, case=f"{op}/{profile}/64")
        samples.append(row)
    assert len(parse_text("\n".join(map(json.dumps, [meta, *samples, end]))).samples) == 4
    samples[0]["impl"] = "fastmem_abi"
    with pytest.raises(ValueError, match="Sample set"):
        parse_text("\n".join(map(json.dumps, [meta, *samples, end])))


def row(case: str, comparison: str, ratio: float = 1) -> dict[str, Any]:
    op, profile, _size = case.split("/")
    return {
        "case": case,
        "comparison": comparison,
        "variant": "v0",
        "op": op,
        "profile": profile,
        "ratio": ratio,
        "ci95": [ratio, ratio],
        "rounds": 5,
        "noise_floor": 0.01,
        "minimum_effect": 0,
        "chunk_bytes": 16,
        "tier": "test",
        "significant": abs(ratio - 1) > 0.01,
        "candidate_ns": ratio * 10,
        "baseline_ns": 10,
    }


def complete_rows() -> list[dict[str, Any]]:
    rows = []
    for case in required_cases("copy", 16):
        rows.extend([row(case, "fastmem_abi/glibc"), row(case, "fastmem_abi/builtin")])
    rows.append(row("copy/dist/small", "fastmem_inline/glibc", 0.85))
    rows.extend(row(f"copy/const/{size}", "fastmem_inline/builtin_const") for size in CONST_SIZES)
    return rows


def test_complete_goals_and_p4_codegen_boundary() -> None:
    goal = evaluate(complete_rows(), ["v0"])[0]
    assert goal["G2"]["status"] == "PASS"
    assert goal["G3"]["status"] == "PASS"
    assert goal["G4"]["status"] == "NA"
    assert goal["G4"]["timing_status"] == "PASS"
    assert goal["G4"]["no_call"]["reason"] == "checked by binary test, P4"
    assert all(item["G2"]["status"] == "NA" for item in evaluate([], ["v0"]))


@pytest.mark.parametrize(("field", "value"), [("rounds", 4), ("noise_floor", None)])
def test_goals_require_rounds_and_aa(field: str, value: int | None) -> None:
    rows = complete_rows()
    for item in rows:
        item[field] = value
    goals = evaluate(rows, ["v0"])[0]
    assert all(goals[name]["status"] == "NA" for name in ("G2", "G3", "G4"))


def test_goal_components_fail_independently() -> None:
    rows = complete_rows()
    rows = [item for item in rows if item["case"] != "copy/const/256"]
    for item in rows:
        if item["case"] == "copy/aligned/64":
            item.update(ratio=1.2, ci95=[1.19, 1.21], significant=True)
    goal = evaluate(rows, ["v0"])[0]
    assert goal["G2"]["status"] == "FAIL"
    assert goal["G3"]["status"] == "FAIL"
    assert goal["G4"]["small"]["status"] == "PASS"
    assert goal["G4"]["const"]["status"] == "NA"
    assert goal["G4"]["const"]["missing_cases"] == ["copy/const/256"]


def test_comparisons_and_partial_goals(tmp_path: Path) -> None:
    for variant in ("v0", "v1", "aa"):
        for index in range(5):
            measurement(tmp_path / variant / f"r{index}.jsonl")
    result = analyze(tmp_path, ["v0", "v1"], "v0", probe=PROBE)
    assert {item["comparison"] for item in result["rows"]} == {
        "A/A",
        "revision",
        "builtin/glibc",
        "fastmem_abi/glibc",
        "fastmem_inline/glibc",
        "fastmem_abi/builtin",
    }
    assert {
        item["candidate_impl"] for item in result["rows"] if item["comparison"] == "revision"
    } == {
        "fastmem_abi",
        "fastmem_inline",
    }
    assert all(item["G2"]["status"] == "NA" for item in result["goals"])


def test_protocol_probe_mismatch_stops_target(config: Any) -> None:
    from fastmem_bench.protocol import execute

    class WrongProbe(FakeBox):
        def run(self, command: str, **kwargs: Any) -> str:
            result = super().run(command, **kwargs)
            if command.endswith("/libc-probe"):
                probe = json.loads(result)
                probe["symbols"]["memset"]["offset"] = "0xdead"
                return json.dumps(probe)
            return result

    path, build = setup(config)
    box: Any = WrongProbe()
    with pytest.raises(ValueError, match="memset offset disagrees"):
        execute(
            config, box, [build], path, suite="quick", schedule=[["v0"], ["v0"]], aa=False, seed=1
        )
    assert len([command for command in box.commands if command.startswith("systemd-run")]) == 1
    assert any("glibc-memset.asm" in command for command in box.commands)
    assert box.downloaded


def test_g2_includes_distributions() -> None:
    rows = complete_rows()
    for item in rows:
        if item["case"] == "copy/dist/small" and item["comparison"] == "fastmem_abi/glibc":
            item.update(ratio=1.2, ci95=[1.19, 1.21])
    goal = evaluate(rows, ["v0"])[0]["G2"]
    assert goal["status"] == "FAIL"
    assert goal["significant_above_1_10"][0]["case"] == "copy/dist/small"
    partial = [item for item in rows if item["case"] != "copy/dist/mixed"]
    assert evaluate(partial, ["v0"])[0]["G2"]["status"] == "NA"


def test_goal_ci_threshold_does_not_add_aa_floor() -> None:
    rows = complete_rows()
    for item in rows:
        item.update(noise_floor=0.25, minimum_effect=0.25, significant=False)
        if item["case"] == "copy/aligned/64":
            item.update(ratio=1.12, ci95=[1.11, 1.13])
    goals = evaluate(rows, ["v0"])[0]
    assert goals["G2"]["status"] == "FAIL"
    assert goals["G3"]["status"] == "FAIL"
    assert len(goals["G2"]["significant_above_1_10"]) == 1
