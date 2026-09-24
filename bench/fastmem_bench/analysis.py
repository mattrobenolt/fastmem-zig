"""Round-cluster bootstrap ratios and pooled operation/size noise floors."""

import logging
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from fastmem_bench.goals import evaluate
from fastmem_bench.jsonl import IMPLEMENTATIONS, parse

BOOTSTRAP_SEED = 20260923
TIERS = (
    (16, "0-16"),
    (64, "17-64"),
    (256, "65-256"),
    (1024, "257-1024"),
    (16384, "1025-16384"),
    (math.inf, ">16384"),
)


def tier(size: float) -> str:
    return next(name for maximum, name in TIERS if size <= maximum)


def median(rounds: list[list[float]]) -> float:
    return statistics.median(value for samples in rounds for value in samples)


def ratio(candidate: list[list[float]], baseline: list[list[float]]) -> float:
    denominator = median(baseline)
    if denominator <= 0:
        raise ValueError("A ratio requires a positive baseline median")
    return median(candidate) / denominator


def bootstrap(
    candidate: list[list[float]],
    baseline: list[list[float]],
    *,
    seed: int = BOOTSTRAP_SEED,
    iterations: int = 2000,
) -> tuple[float, float]:
    if len(candidate) != len(baseline) or not candidate:
        raise ValueError("Bootstrap requires matched nonempty rounds")
    rng = random.Random(seed)  # noqa: S311 — reproducible statistical sampling
    values = []
    for _ in range(iterations):
        indices = rng.choices(range(len(candidate)), k=len(candidate))
        values.append(
            ratio([candidate[index] for index in indices], [baseline[index] for index in indices])
        )
    values.sort()
    return values[int(iterations * 0.025)], values[min(iterations - 1, int(iterations * 0.975))]


def significant(value: float, interval: tuple[float, float], floor: float | None) -> bool:
    return floor is not None and (interval[1] < 1 or interval[0] > 1) and abs(value - 1) > floor


def geomean(values: list[float]) -> float:
    if not values or any(value <= 0 for value in values):
        raise ValueError("Geometric means require positive ratios")
    return math.exp(statistics.fmean(math.log(value) for value in values))


def load_rounds(  # noqa: C901 — validate clusters before case intersection
    raw: Path,
    variants: list[str],
    *,
    expected_round_count: int | None = None,
    probe: dict[str, Any] | None = None,
) -> tuple[
    dict[tuple[str, str, str], dict[int, list[float]]], dict[str, dict[str, Any]], list[str]
]:
    data: dict[tuple[str, str, str], dict[int, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    details: dict[str, dict[str, Any]] = {}
    variant_cases: dict[str, set[tuple[str, str]]] = {}
    expected_rounds: set[int] | None = None
    for variant in variants:
        paths = sorted((raw / variant).glob("r*.jsonl"))
        if not paths:
            raise ValueError(f"No complete rounds for {variant}")
        rounds = {int(path.stem[1:]) for path in paths}
        if expected_rounds is not None and rounds != expected_rounds:
            raise ValueError("Variants have different round sets")
        if rounds != set(range(expected_round_count or len(rounds))):
            raise ValueError(f"Incomplete round set for {variant}: {sorted(rounds)}")
        expected_rounds = rounds
        for path in paths:
            measurement = parse(path, probe=probe)
            cases = {(sample["case"], sample["impl"]) for sample in measurement.samples}
            if variant in variant_cases and cases != variant_cases[variant]:
                raise ValueError(f"Rounds have different case/implementation sets within {variant}")
            variant_cases[variant] = cases
            for sample in measurement.samples:
                case = sample["case"]
                detail = {key: sample[key] for key in ("op", "size", "profile")}
                detail["chunk_bytes"] = measurement.meta["chunk_bytes"]
                if case in details and detail != details[case]:
                    raise ValueError(f"Case metadata changed for {case}")
                details[case] = detail
                data[variant, case, sample["impl"]][int(path.stem[1:])].append(
                    sample["ns"] / sample["iters"]
                )
    common = set.intersection(*variant_cases.values())
    warnings = []
    for variant, cases in variant_cases.items():
        if excluded := cases - common:
            warning = (
                f"{variant}: excluded {len(excluded)} unmatched case/implementation pairs: "
                + ", ".join(f"{case}:{impl}" for case, impl in sorted(excluded))
            )
            warnings.append(warning)
            logging.getLogger(__name__).warning("%s", warning)
    if not common:
        raise ValueError("Variants have no common case/implementation pairs")
    data = {key: rounds for key, rounds in data.items() if (key[1], key[2]) in common}
    common_cases = {case for case, _impl in common}
    details = {case: detail for case, detail in details.items() if case in common_cases}
    return data, details, warnings


def floor_group(detail: dict[str, Any]) -> str:
    if detail["profile"] == "dist":
        return f"{detail['op']}/tier/{tier(detail['size'])}"
    return f"{detail['op']}/size/{detail['size']:g}"


def validate_effect(minimum_effect: float) -> None:
    if not math.isfinite(minimum_effect) or minimum_effect < 0:
        raise ValueError("The minimum effect must be a finite nonnegative fraction")


def analyze(  # noqa: C901 — paired comparisons share one cluster table
    raw: Path,
    variants: list[str],
    baseline: str,
    *,
    aa: str | None = "aa",
    minimum_effect: float = 0.0,
    expected_round_count: int | None = None,
    probe: dict[str, Any] | None = None,
) -> dict[str, Any]:
    validate_effect(minimum_effect)
    data, details, warnings = load_rounds(
        raw,
        [*variants, *([aa] if aa else [])],
        expected_round_count=expected_round_count,
        probe=probe,
    )

    def clusters(variant: str, case: str, impl: str) -> list[list[float]]:
        rounds = data.get((variant, case, impl), {})
        return [rounds[index] for index in sorted(rounds)]

    rows: list[dict[str, Any]] = []

    def compare(  # noqa: PLR0917 — paired variant/implementation identifiers
        case: str,
        kind: str,
        candidate: str,
        candidate_impl: str,
        reference: str,
        reference_impl: str,
    ) -> None:
        left, right = (
            clusters(candidate, case, candidate_impl),
            clusters(reference, case, reference_impl),
        )
        if not left or not right:
            return
        value = ratio(left, right)
        interval = bootstrap(left, right)
        rows.append(
            {
                "case": case,
                **details[case],
                "tier": tier(details[case]["size"]),
                "comparison": kind,
                "variant": candidate,
                "reference": reference,
                "candidate_impl": candidate_impl,
                "reference_impl": reference_impl,
                "candidate_ns": median(left),
                "baseline_ns": median(right),
                "ratio": value,
                "ci95": list(interval),
                "rounds": len(left),
                "floor_group": floor_group(details[case]),
            }
        )

    for case in sorted(details):
        if aa:
            for implementation in IMPLEMENTATIONS:
                compare(case, "A/A", aa, implementation, baseline, implementation)
        for variant in variants:
            if variant != baseline:
                for implementation in ("fastmem_abi", "fastmem_inline"):
                    compare(case, "revision", variant, implementation, baseline, implementation)
            for candidate, reference in (
                ("builtin", "glibc"),
                ("fastmem_abi", "glibc"),
                ("fastmem_inline", "glibc"),
                ("fastmem_abi", "builtin"),
                ("fastmem_inline", "builtin_const"),
            ):
                compare(case, f"{candidate}/{reference}", variant, candidate, variant, reference)
    result = summarize(rows, warnings, minimum_effect)
    result["goals"] = evaluate(rows, variants)
    return result


def summarize(
    rows: list[dict[str, Any]], warnings: list[str], minimum_effect: float
) -> dict[str, Any]:
    noise_floors: dict[str, float] = {}
    for row in rows:
        if row["comparison"] == "A/A":
            departure = max(abs(row["ratio"] - 1), *(abs(bound - 1) for bound in row["ci95"]))
            key = row["floor_group"]
            noise_floors[key] = max(noise_floors.get(key, 0), departure)
    if any(row["rounds"] < 5 for row in rows):
        warnings.append("Fewer than five rounds: significance marks are disabled.")
    groups: dict[tuple[str, str, str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        floor = noise_floors.get(row["floor_group"])
        row["noise_floor"] = floor
        row["minimum_effect"] = minimum_effect
        row["significant"] = (
            row["comparison"] != "A/A"
            and row["rounds"] >= 5
            and significant(
                row["ratio"],
                tuple(row["ci95"]),
                max(floor, minimum_effect) if floor is not None else None,
            )
        )
        groups[
            row["comparison"], row["variant"], row["op"], row["tier"], row["candidate_impl"]
        ].append(row["ratio"])
    tiers = [
        {
            "comparison": key[0],
            "variant": key[1],
            "op": key[2],
            "tier": key[3],
            "candidate_impl": key[4],
            "geomean": geomean(values),
            "cases": len(values),
        }
        for key, values in sorted(groups.items())
    ]
    return {
        "noise_floors": noise_floors,
        "minimum_effect": minimum_effect,
        "rows": rows,
        "tiers": tiers,
        "warnings": warnings,
    }
