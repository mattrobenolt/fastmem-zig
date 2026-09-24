"""Timing components of G2-G4 from docs/fastmem-plan.md.

Incomplete suites never pass. G4 code generation belongs to the P4 binary test.
"""

from collections.abc import Callable
from typing import Any

STANDARD_SIZES = (
    0,
    1,
    2,
    3,
    4,
    7,
    8,
    15,
    16,
    24,
    31,
    32,
    48,
    63,
    64,
    96,
    127,
    128,
    192,
    255,
    256,
    384,
    511,
    512,
    768,
    1024,
    2048,
    4096,
    8192,
    16384,
    65536,
    262144,
    1048576,
)
CONST_SIZES = (1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256)
MIN_ROUNDS = 5
# G3 tests hundreds of cases against 1.00. A case violates G3 only when its whole
# interval lies above 1 + max(A/A floor, G3_MARGIN).
G3_MARGIN = 0.01
G3_RULE = f"lower > 1 + max(floor, {G3_MARGIN:g})"


def required_cases(op: str, chunk: int) -> set[str]:
    profiles = {
        "copy": ["aligned", "misaligned", "cross-lane", "page-offset"],
        "move": ["disjoint"]
        + [
            f"{direction}-gap{gap}"
            for direction in ("fwd", "bwd")
            for gap in (1, chunk - 1, chunk + 1)
        ],
        "set": ["aligned", "misaligned"],
    }[op]
    return {f"{op}/{profile}/{size}" for profile in profiles for size in STANDARD_SIZES} | {
        f"{op}/dist/small",
        f"{op}/dist/mixed",
    }


def evidence_status(rows: list[dict[str, Any]], required: set[str]) -> dict[str, Any]:
    observed = {row["case"] for row in rows}
    missing = sorted(required - observed)
    insufficient = sum(row["rounds"] < MIN_ROUNDS for row in rows)
    eligible = (
        bool(rows) and not insufficient and all(row["noise_floor"] is not None for row in rows)
    )
    return {
        "cases": len(rows),
        "required_cases": len(required),
        "missing_cases": missing,
        "rounds": min((row["rounds"] for row in rows), default=0),
        "insufficient_evidence": insufficient,
        "ci_levels": sorted({row["ci_level"] for row in rows if "ci_level" in row}),
        "aa_available": bool(rows) and all(row["noise_floor"] is not None for row in rows),
        "eligible": eligible and not missing,
    }


def verdict(evidence: dict[str, Any], passed: bool) -> str:
    return ("PASS" if passed else "FAIL") if evidence["eligible"] else "NA"


def slowdown(row: dict[str, Any], threshold: float) -> bool:
    return row["ci95"][0] > threshold


def compiler_slowdown(row: dict[str, Any]) -> bool:
    """G3: the whole interval lies above 1 + max(floor, G3_MARGIN)."""
    floor = row["noise_floor"]
    return floor is not None and slowdown(row, 1 + max(floor, G3_MARGIN))


def null_reference(
    rows: list[dict[str, Any]],
    op: str,
    impl: str,
    cases: set[str],
    *,
    rule: str,
    violates: Callable[[dict[str, Any]], bool],
) -> dict[str, Any]:
    """Apply a goal rule to the A/A rows of the same cases: the violations of a null.

    A/A rows compare separate processes. They use the two-sample interval, not the
    paired interval of the goal rows, so the count is a reference, not a verdict.
    """
    null = [
        row
        for row in rows
        if row["comparison"] == "A/A"
        and row["op"] == op
        and row["candidate_impl"] == impl
        and row["case"] in cases
    ]
    return {
        "impl": impl,
        "rule": rule,
        "cases": len(null),
        "violations": sum(violates(row) for row in null),
    }


def evaluate(
    rows: list[dict[str, Any]],
    variants: list[str],
    *,
    codegen: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    # Import here to keep the statistical implementation in one module.
    from fastmem_bench.analysis import geomean

    goals = []
    for variant in variants:
        for op in ("copy", "move", "set"):
            selected = [row for row in rows if row["variant"] == variant and row["op"] == op]
            chunk = next((row["chunk_bytes"] for row in selected), 16)
            standard = required_cases(op, chunk)
            kernel = [
                row
                for row in selected
                if row["comparison"] == "fastmem_abi/glibc" and row["case"] in standard
            ]
            g2 = evidence_status(kernel, standard)
            overall = geomean([row["ratio"] for row in kernel]) if kernel else None
            tiers = {
                tier: geomean([row["ratio"] for row in kernel if row["tier"] == tier])
                for tier in sorted({row["tier"] for row in kernel})
            }
            regressions = [row for row in kernel if slowdown(row, 1.10)]
            g2.update(
                geomean=overall,
                tier_geomeans=tiers,
                significant_above_1_10=[detail(row) for row in regressions],
                aa_reference=null_reference(
                    rows,
                    op,
                    "fastmem_abi",
                    standard,
                    rule="lower > 1.10",
                    violates=lambda row: slowdown(row, 1.10),
                ),
                status=verdict(
                    g2,
                    overall is not None
                    and overall <= 1
                    and all(value <= 1.05 for value in tiers.values())
                    and not regressions,
                ),
            )
            compiler = [row for row in selected if row["comparison"] == "fastmem_abi/builtin"]
            g3 = evidence_status(compiler, standard)
            regressions = [row for row in compiler if compiler_slowdown(row)]
            g3.update(
                worst_ratio=max((row["ratio"] for row in compiler), default=None),
                rule=G3_RULE,
                violations=[detail(row) for row in regressions],
                aa_reference=null_reference(
                    rows, op, "fastmem_abi", standard, rule=G3_RULE, violates=compiler_slowdown
                ),
                status=verdict(g3, not regressions),
            )
            small = [
                row
                for row in selected
                if row["comparison"] == "fastmem_inline/glibc" and row["case"] == f"{op}/dist/small"
            ]
            small_evidence = evidence_status(small, {f"{op}/dist/small"})
            small_ratio = small[0]["ratio"] if small else None
            small_evidence.update(
                ratio=small_ratio,
                measurements=[detail(row) for row in small],
                status=verdict(small_evidence, small_ratio is not None and small_ratio <= 0.90),
            )
            constant = [
                row for row in selected if row["comparison"] == "fastmem_inline/builtin_const"
            ]
            const_cases = {f"copy/const/{size}" for size in CONST_SIZES}
            const_evidence = evidence_status(constant, const_cases)
            const_regressions = [row for row in constant if slowdown(row, 1)]
            const_evidence.update(
                measurements=[detail(row) for row in constant],
                significant_above_1=[detail(row) for row in const_regressions],
                aa_reference=null_reference(
                    rows,
                    op,
                    "fastmem_inline",
                    const_cases,
                    rule="lower > 1.00",
                    violates=lambda row: slowdown(row, 1),
                ),
                status=verdict(const_evidence, not const_regressions),
            )
            if op != "copy":
                const_evidence = {
                    "status": "NA",
                    "reason": "The const copy requirement does not apply to this operation.",
                }
            components = [small_evidence["status"]]
            if op == "copy":
                components.append(const_evidence["status"])
            timing = "FAIL" if "FAIL" in components else "NA" if "NA" in components else "PASS"
            g4 = {
                "status": "FAIL" if timing == "FAIL" else "NA" if op == "copy" else timing,
                "timing_status": timing,
                "small": small_evidence,
                "const": const_evidence,
                "no_call": {"status": "NA", "reason": "checked by binary test, P4"},
            }
            for goal in (g2, g3):
                if goal["status"] == "NA":
                    goal["reason"] = na_reason(goal, "The complete case set")
            if small_evidence["status"] == "NA":
                small_evidence["reason"] = na_reason(small_evidence, "The small distribution")
            if op == "copy" and const_evidence["status"] == "NA":
                const_evidence["reason"] = na_reason(const_evidence, "All const sizes")
            apply_codegen(g2, g3, (codegen or {}).get(variant))
            goals.append({"variant": variant, "op": op, "G2": g2, "G3": g3, "G4": g4})
    return goals


def na_reason(evidence: dict[str, Any], cases: str) -> str:
    reason = f"{cases}, {MIN_ROUNDS} rounds, and A/A evidence are required."
    if evidence["insufficient_evidence"]:
        reason = f"Insufficient evidence: fewer than {MIN_ROUNDS} rounds. {reason}"
    return reason


def detail(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: row[key]
        for key in (
            "case",
            "ratio",
            "ci95",
            "ci_level",
            "ci_method",
            "rounds",
            "evidence",
            "noise_floor",
            "candidate_ns",
            "baseline_ns",
            "significant",
            "outlier_rounds",
        )
        if key in row
    }


def apply_codegen(g2: dict[str, Any], g3: dict[str, Any], evidence: dict[str, Any] | None) -> None:
    if evidence is None:
        for goal in (g2, g3):
            goal.update(status="NA", reason="The binary has no codegen evidence.")
        return
    symbols = sorted({call["symbol"] for call in evidence["delegations"]})
    if symbols:
        reasons = [f"fastmem delegates to {symbol}" for symbol in symbols]
        for goal in (g2, g3):
            goal.update(
                status="INVALID",
                reason=". ".join(reasons),
                reasons=reasons,
                delegations=evidence["delegations"],
            )
