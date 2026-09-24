"""Timing components of G2-G4 from docs/fastmem-plan.md.

Incomplete suites never pass. G4 code generation belongs to the P4 binary test.
"""

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
    return {f"{op}/{profile}/{size}" for profile in profiles for size in STANDARD_SIZES}


def evidence_status(rows: list[dict[str, Any]], required: set[str]) -> dict[str, Any]:
    observed = {row["case"] for row in rows}
    missing = sorted(required - observed)
    eligible = bool(rows) and all(
        row["rounds"] >= 5 and row["noise_floor"] is not None for row in rows
    )
    return {
        "cases": len(rows),
        "required_cases": len(required),
        "missing_cases": missing,
        "rounds": min((row["rounds"] for row in rows), default=0),
        "aa_available": bool(rows) and all(row["noise_floor"] is not None for row in rows),
        "eligible": eligible and not missing,
    }


def verdict(evidence: dict[str, Any], passed: bool) -> str:
    return ("PASS" if passed else "FAIL") if evidence["eligible"] else "NA"


def slowdown(row: dict[str, Any], threshold: float) -> bool:
    return (
        row["significant"]
        and row["ci95"][0] > threshold
        and row["ratio"] - threshold > max(row["noise_floor"] or 0, row["minimum_effect"])
    )


def evaluate(rows: list[dict[str, Any]], variants: list[str]) -> list[dict[str, Any]]:
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
                status=verdict(
                    g2,
                    overall is not None
                    and overall <= 1
                    and all(value <= 1.05 for value in tiers.values())
                    and not regressions,
                ),
            )
            compiler = [row for row in selected if row["comparison"] == "fastmem_abi/builtin"]
            g3 = evidence_status(compiler, standard | {f"{op}/dist/small", f"{op}/dist/mixed"})
            regressions = [row for row in compiler if slowdown(row, 1)]
            g3.update(
                worst_ratio=max((row["ratio"] for row in compiler), default=None),
                significant_above_1=[detail(row) for row in regressions],
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
            const_evidence = evidence_status(
                constant, {f"copy/const/{size}" for size in CONST_SIZES}
            )
            const_regressions = [row for row in constant if slowdown(row, 1)]
            const_evidence.update(
                measurements=[detail(row) for row in constant],
                significant_above_1=[detail(row) for row in const_regressions],
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
                    goal["reason"] = (
                        "The complete case set, five rounds, and A/A evidence are required."
                    )
            if small_evidence["status"] == "NA":
                small_evidence["reason"] = (
                    "The small distribution, five rounds, and A/A evidence are required."
                )
            if op == "copy" and const_evidence["status"] == "NA":
                const_evidence["reason"] = (
                    "All const sizes, five rounds, and A/A evidence are required."
                )
            goals.append({"variant": variant, "op": op, "G2": g2, "G3": g3, "G4": g4})
    return goals


def detail(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: row[key]
        for key in (
            "case",
            "ratio",
            "ci95",
            "rounds",
            "noise_floor",
            "candidate_ns",
            "baseline_ns",
            "significant",
        )
    }
