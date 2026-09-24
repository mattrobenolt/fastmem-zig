"""Robust round-level ratios, exact rank intervals, and A/A noise floors.

One round is one process run, and the round is the unit of independence.
Each (variant, case, implementation, round) cell reduces to the median of its
samples. A ratio compares the round medians of two cells on the log scale.
The design and its evidence are in docs/bench-design.md, section "Analysis".
"""

import logging
import math
import statistics
from collections import defaultdict
from collections.abc import Collection
from functools import cache
from pathlib import Path
from typing import Any

from fastmem_bench.goals import evaluate
from fastmem_bench.jsonl import IMPLEMENTATIONS, parse

# The estimator has no random component. The runner still records this value.
BOOTSTRAP_SEED = 20260923
CONFIDENCE = 0.95
FLOOR_QUANTILE = 0.95
OUTLIER_Z = 5.0
OUTLIER_MIN = math.log1p(0.05)
OUTLIER_SCALE_MIN = 0.005
OUTLIER_MIN_ROUNDS = 5
MAD_TO_SD = 1.4826
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


def round_medians(rounds: list[list[float]]) -> list[float]:
    if not rounds or any(not samples for samples in rounds):
        raise ValueError("Every round requires samples")
    values = [statistics.median(samples) for samples in rounds]
    if any(value <= 0 for value in values):
        raise ValueError("Round medians must be positive")
    return values


def outlier_rounds(values: list[float]) -> list[int]:
    """Return the one round that departs from the other rounds of its cell, if any.

    A round departs when its log distance from the median of the other rounds
    exceeds both OUTLIER_Z robust standard deviations of those rounds and
    OUTLIER_MIN. Two or more departing rounds indicate a multimodal cell, not
    a spike, so no round is flagged.
    """
    if len(values) < OUTLIER_MIN_ROUNDS:
        return []
    logs = [math.log(value) for value in values]
    flagged = []
    for index, value in enumerate(logs):
        others = logs[:index] + logs[index + 1 :]
        center = statistics.median(others)
        spread = MAD_TO_SD * statistics.median(abs(other - center) for other in others)
        if abs(value - center) > max(OUTLIER_Z * max(spread, OUTLIER_SCALE_MIN), OUTLIER_MIN):
            flagged.append(index)
    return flagged if len(flagged) == 1 else []


@cache
def rank_counts(n: int, m: int) -> tuple[int, ...]:
    """Count the orderings of n + m values by the Mann-Whitney statistic U."""
    if n == 0 or m == 0:
        return (1,)
    counts = [0] * (n * m + 1)
    # The largest value is either in the first sample (it exceeds all m) or in the second.
    for u, count in enumerate(rank_counts(n - 1, m)):
        counts[u + m] += count
    for u, count in enumerate(rank_counts(n, m - 1)):
        counts[u] += count
    return tuple(counts)


@cache
def rank_interval(n: int, m: int, level: float = CONFIDENCE) -> tuple[int, float]:
    """Return k and the exact coverage of [d_(k), d_(nm+1-k)] of the pairwise differences.

    If no interval reaches the level, k is 1: the full range and its coverage.
    """
    if n < 1 or m < 1:
        raise ValueError("Intervals require nonempty samples")
    counts = rank_counts(n, m)
    total = math.comb(n + m, n)
    k, below = 1, counts[0]
    while 2 * (k + 1) <= n * m + 1 and 1 - 2 * (below + counts[k]) / total >= level:
        below += counts[k]
        k += 1
    return k, 1 - 2 * below / total


def hodges_lehmann(candidate: list[float], baseline: list[float]) -> float:
    return statistics.median(x - y for x in candidate for y in baseline)


def compare_rounds(
    candidate: list[float],
    baseline: list[float],
    *,
    candidate_outliers: Collection[int] = (),
    baseline_outliers: Collection[int] = (),
) -> dict[str, Any]:
    """Compare positive round medians. Outlier rounds leave the interval, not the estimate."""
    left = [math.log(value) for value in candidate]
    right = [math.log(value) for value in baseline]
    point = hodges_lehmann(left, right)
    kept_left = [value for index, value in enumerate(left) if index not in candidate_outliers]
    kept_right = [value for index, value in enumerate(right) if index not in baseline_outliers]
    k, coverage = rank_interval(len(kept_left), len(kept_right))
    differences = sorted(x - y for x in kept_left for y in kept_right)
    low = min(differences[k - 1], point)
    high = max(differences[-k], point)
    return {
        "ratio": math.exp(point),
        "ci95": [math.exp(low), math.exp(high)],
        "ci_level": coverage,
        "ci_rounds": [len(kept_left), len(kept_right)],
    }


def quantile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("Quantiles require values")
    position = (len(ordered) - 1) * fraction
    below = math.floor(position)
    above = min(below + 1, len(ordered) - 1)
    return ordered[below] + (ordered[above] - ordered[below]) * (position - below)


def significant(value: float, interval: tuple[float, float], floor: float | None) -> bool:
    return (
        floor is not None
        and (interval[1] < 1 or interval[0] > 1)
        and abs(math.log(value)) > math.log1p(floor)
    )


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
    dict[tuple[str, str, str], dict[int, list[float]]],
    dict[str, dict[str, Any]],
    list[str],
    dict[str, Any],
]:
    data: dict[tuple[str, str, str], dict[int, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    details: dict[str, dict[str, Any]] = {}
    variant_cases: dict[str, set[tuple[str, str]]] = {}
    codegen: dict[str, Any] = {}
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
            evidence = measurement.meta["codegen"]
            if variant in codegen and codegen[variant] != evidence:
                raise ValueError(f"Codegen evidence changed within {variant}")
            codegen[variant] = evidence
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
    return data, details, warnings, codegen


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
    data, details, warnings, codegen = load_rounds(
        raw,
        [*variants, *([aa] if aa else [])],
        expected_round_count=expected_round_count,
        probe=probe,
    )
    cells: dict[tuple[str, str, str], tuple[list[float], list[int]]] = {}
    for key in sorted(data):
        rounds = data[key]
        values = round_medians([rounds[index] for index in sorted(rounds)])
        cells[key] = (values, outlier_rounds(values))
    outliers = [
        {
            "variant": variant,
            "case": case,
            "impl": impl,
            "round": index,
            "ratio": values[index] / statistics.median(values[:index] + values[index + 1 :]),
        }
        for (variant, case, impl), (values, flagged) in cells.items()
        for index in flagged
    ]

    rows: list[dict[str, Any]] = []

    def compare(  # noqa: PLR0917 — paired variant/implementation identifiers
        case: str,
        kind: str,
        candidate: str,
        candidate_impl: str,
        reference: str,
        reference_impl: str,
    ) -> None:
        left = cells.get((candidate, case, candidate_impl))
        right = cells.get((reference, case, reference_impl))
        if left is None or right is None:
            return
        estimate = compare_rounds(
            left[0], right[0], candidate_outliers=left[1], baseline_outliers=right[1]
        )
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
                "candidate_ns": statistics.median(left[0]),
                "baseline_ns": statistics.median(right[0]),
                **estimate,
                "outlier_rounds": {"candidate": left[1], "baseline": right[1]},
                "rounds": min(len(left[0]), len(right[0])),
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
    result["outliers"] = outliers
    result["codegen"] = codegen
    result["goals"] = evaluate(rows, variants, codegen=codegen)
    return result


def summarize(
    rows: list[dict[str, Any]], warnings: list[str], minimum_effect: float
) -> dict[str, Any]:
    departures: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        if row["comparison"] == "A/A":
            departures[row["floor_group"]].append(abs(math.log(row["ratio"])))
    noise_floors = {
        group: math.expm1(quantile(values, FLOOR_QUANTILE)) for group, values in departures.items()
    }
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
        "floor_quantile": FLOOR_QUANTILE,
        "minimum_effect": minimum_effect,
        "rows": rows,
        "tiers": tiers,
        "warnings": warnings,
    }
