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


def test_g2_threshold_does_not_add_aa_floor_but_g3_does() -> None:
    rows = complete_rows()
    for item in rows:
        item.update(noise_floor=0.25, minimum_effect=0.25, significant=False)
        if item["case"] == "copy/aligned/64":
            item.update(ratio=1.12, ci95=[1.11, 1.13])
    goals = evaluate(rows, ["v0"])[0]
    assert goals["G2"]["status"] == "FAIL"
    assert len(goals["G2"]["significant_above_1_10"]) == 1
    # G3 needs the whole interval above 1 + max(floor, 0.01) = 1.25.
    assert goals["G3"]["status"] == "PASS"
    assert goals["G3"]["rule"] == "lower > 1 + max(floor, 0.01)"


@pytest.mark.parametrize(
    ("floor", "lower", "status"),
    [
        (0.005, 1.009, "PASS"),
        (0.005, 1.011, "FAIL"),
        (0.02, 1.015, "PASS"),
        (0.02, 1.021, "FAIL"),
    ],
)
def test_g3_margin_is_the_larger_of_floor_and_one_percent(
    floor: float, lower: float, status: str
) -> None:
    rows = complete_rows()
    for item in rows:
        item["noise_floor"] = floor
        if item["case"] == "copy/aligned/64" and item["comparison"] == "fastmem_abi/builtin":
            item.update(ratio=lower + 0.01, ci95=[lower, lower + 0.02])
    goal = evaluate(rows, ["v0"])[0]["G3"]
    assert goal["status"] == status
    assert len(goal["violations"]) == (status == "FAIL")


def test_insufficient_evidence_gives_no_goal_verdict() -> None:
    rows = complete_rows()
    for item in rows:
        item["rounds"] = 3
    goal = evaluate(rows, ["v0"])[0]
    for name in ("G2", "G3"):
        assert goal[name]["status"] == "NA"
        assert goal[name]["insufficient_evidence"] == goal[name]["cases"]
        assert goal[name]["reason"].startswith("Insufficient evidence: fewer than 5 rounds.")


def test_goals_report_the_aa_null_reference() -> None:
    rows = complete_rows()
    null = []
    for case in sorted(required_cases("copy", 16)):
        item = row(case, "A/A")
        item.update(variant="aa", candidate_impl="fastmem_abi")
        null.append(item)
    null[0].update(ratio=1.2, ci95=[1.15, 1.25])
    null[1].update(ratio=1.03, ci95=[1.01, 1.05])
    for size in CONST_SIZES:
        item = row(f"copy/const/{size}", "A/A")
        # Only the 256-byte row is above 1 + max(floor, 0.01): the const rule is the G3 rule.
        lower = 1.02 if size == 256 else 1.001
        item.update(variant="aa", candidate_impl="fastmem_inline", ci95=[lower, lower + 0.001])
        null.append(item)
    for item in rows:
        item.setdefault("candidate_impl", item["comparison"].split("/")[0])
    goal = evaluate(rows + null, ["v0"])[0]
    assert goal["G2"]["aa_reference"] == {
        "impl": "fastmem_abi",
        "rule": "lower > 1.10",
        "cases": len(required_cases("copy", 16)),
        "violations": 1,
    }
    # G3 applies its own rule: 1.01 is not above 1 + max(0.01, 0.01).
    assert goal["G3"]["aa_reference"]["violations"] == 1
    assert goal["G4"]["const"]["aa_reference"] == {
        "impl": "fastmem_inline",
        "rule": "lower > 1 + max(floor, 0.01)",
        "cases": len(CONST_SIZES),
        "violations": 1,
    }
    # The null reference is evidence only. It does not change a verdict.
    assert goal["G2"]["status"] == "PASS"
    assert goal["G3"]["status"] == "PASS"


def op_rows(op: str) -> list[dict[str, Any]]:
    rows = []
    for case in required_cases(op, 16):
        rows.extend([row(case, "fastmem_abi/glibc"), row(case, "fastmem_abi/builtin")])
    rows.append(row(f"{op}/dist/small", "fastmem_inline/glibc", 0.85))
    rows.extend(row(f"{op}/const/{size}", "fastmem_inline/builtin_const") for size in CONST_SIZES)
    return rows


def test_g4_const_covers_every_operation() -> None:
    rows = op_rows("move") + [item for item in op_rows("set") if item["case"] != "set/const/256"]
    for item in rows:
        if item["case"] == "move/const/64":
            item.update(ratio=1.05, ci95=[1.03, 1.07])
    goals = {goal["op"]: goal["G4"] for goal in evaluate(rows, ["v0"])}
    assert goals["move"]["const"]["status"] == "FAIL"
    assert goals["move"]["status"] == "FAIL"
    assert goals["move"]["const"]["significant_above_1"][0]["case"] == "move/const/64"
    assert goals["set"]["const"]["status"] == "NA"
    assert goals["set"]["const"]["missing_cases"] == ["set/const/256"]
    assert goals["set"]["small"]["status"] == "PASS"
    # A copy run without const cases (schema v2 move/set) has no const verdict.
    assert goals["copy"]["const"]["status"] == "NA"


def test_g4_timing_pass_leaves_the_no_call_check_open() -> None:
    goals = {goal["op"]: goal["G4"] for goal in evaluate(op_rows("set"), ["v0"])}
    assert goals["set"]["timing_status"] == "PASS"
    assert goals["set"]["status"] == "NA"


def test_g6_applies_only_to_baseline_builds() -> None:
    rows = complete_rows()
    target = evaluate(rows, ["v0"])[0]
    assert target["G6"]["status"] == "NA"
    assert "--cpu baseline" in target["G6"]["reason"]
    assert target["G3"]["status"] == "PASS"
    baseline = evaluate_goals(rows, ["v0"], codegen={"v0": CODEGEN}, cpu_mode="baseline")[0]
    assert baseline["G6"]["status"] == "PASS"
    assert baseline["G6"]["rule"] == "lower > 1 + max(floor, 0.01)"
    for name in ("G2", "G3", "G4"):
        assert baseline[name]["status"] == "NA"
        assert "baseline CPU" in baseline[name]["reason"]
    # The evidence stays available for reading.
    assert baseline["G2"]["geomean"] == 1
    with pytest.raises(ValueError, match="Unknown CPU mode"):
        evaluate_goals(rows, ["v0"], cpu_mode="native")


def test_g6_margin_and_delegation() -> None:
    rows = complete_rows()
    for item in rows:
        if item["case"] == "copy/aligned/64" and item["comparison"] == "fastmem_abi/builtin":
            item.update(ratio=1.03, ci95=[1.02, 1.04])
    goal = evaluate_goals(rows, ["v0"], codegen={"v0": CODEGEN}, cpu_mode="baseline")[0]
    assert goal["G6"]["status"] == "FAIL"
    assert goal["G6"]["violations"][0]["case"] == "copy/aligned/64"
    delegating = {
        **CODEGEN,
        "delegations": [{"caller": "fastmem_copy", "symbol": "memcpy", "address": "0x10"}],
    }
    goal = evaluate_goals(rows, ["v0"], codegen={"v0": delegating}, cpu_mode="baseline")[0]
    assert goal["G6"]["status"] == "INVALID"
    assert goal["G3"]["status"] == "INVALID"
