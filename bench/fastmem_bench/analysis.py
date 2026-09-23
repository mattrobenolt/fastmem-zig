"""Round-cluster bootstrap ratios and target-specific noise floors."""

import math
import random
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from fastmem_bench.jsonl import parse

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


def load_rounds(
    raw: Path, variants: list[str]
) -> tuple[dict[tuple[str, str, str], dict[int, list[float]]], dict[str, dict[str, Any]]]:
    # Each key retains round clusters, not flattened independent samples.
    data: dict[tuple[str, str, str], dict[int, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    details: dict[str, dict[str, Any]] = {}
    expected_cases: set[tuple[str, str]] | None = None
    expected_rounds: set[int] | None = None
    for variant in variants:
        paths = sorted((raw / variant).glob("r*.jsonl"))
        if not paths:
            raise ValueError(f"No complete rounds for {variant}")
        rounds = {int(path.stem[1:]) for path in paths}
        if expected_rounds is not None and rounds != expected_rounds:
            raise ValueError("Variants have different round sets")
        expected_rounds = rounds
        for path in paths:
            measurement = parse(path)
            cases = {(sample["case"], sample["impl"]) for sample in measurement.samples}
            if expected_cases is not None and cases != expected_cases:
                raise ValueError("Rounds have different case/implementation sets")
            expected_cases = cases
            for sample in measurement.samples:
                case = sample["case"]
                details[case] = {"op": sample["op"], "size": sample["size"]}
                data[variant, case, sample["impl"]][int(path.stem[1:])].append(
                    sample["ns"] / sample["iters"]
                )

    return data, details


def analyze(
    raw: Path, variants: list[str], baseline: str, *, aa: str | None = "aa"
) -> dict[str, Any]:
    data, details = load_rounds(raw, [*variants, *([aa] if aa else [])])

    def clusters(variant: str, case: str, impl: str) -> list[list[float]]:
        rounds = data[variant, case, impl]
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
            }
        )

    for case in sorted(details):
        if aa:
            compare(case, "A/A", aa, "fastmem", baseline, "fastmem")
        for variant in variants:
            if variant != baseline:
                compare(case, "revision", variant, "fastmem", baseline, "fastmem")
            for implementation in ("libc", "builtin"):
                compare(
                    case, f"fastmem/{implementation}", variant, "fastmem", variant, implementation
                )
    # Conservative target floor: the largest observed A/A departure or CI endpoint departure.
    noise_floor = max(
        (
            max(abs(row["ratio"] - 1), *(abs(bound - 1) for bound in row["ci95"]))
            for row in rows
            if row["comparison"] == "A/A"
        ),
        default=None,
    )
    groups: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        row["significant"] = row["comparison"] != "A/A" and significant(
            row["ratio"], tuple(row["ci95"]), noise_floor
        )
        groups[row["comparison"], row["variant"], row["op"], row["tier"]].append(row["ratio"])
    tiers = [
        {
            "comparison": key[0],
            "variant": key[1],
            "op": key[2],
            "tier": key[3],
            "geomean": geomean(values),
            "cases": len(values),
        }
        for key, values in sorted(groups.items())
    ]
    return {"noise_floor": noise_floor, "rows": rows, "tiers": tiers}
