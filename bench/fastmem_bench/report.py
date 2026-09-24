"""Machine-readable results and compact human reports."""

import json
import math
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def comparison(row: dict[str, Any]) -> str:
    return (
        f"{row['comparison']} ({row['candidate_impl']})"
        if row["comparison"] in {"A/A", "revision"}
        else row["comparison"]
    )


def write(path: Path, summary: dict[str, Any]) -> None:
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    text = [
        "# Benchmark report",
        "",
        "Ratios below 1 indicate a faster candidate.",
        "",
        "Each round contributes the median of its samples for each case and implementation.",
        "The ratio is the two-sample Hodges-Lehmann estimate over the round medians (log scale).",
        "The interval is the exact Mann-Whitney interval: at least 95% coverage.",
        "A flagged outlier round leaves the interval but stays in the ratio.",
        "The noise floor is the 95th percentile of |log A/A ratio| in the operation/size group,",
        "pooled across profiles and implementations. Distribution cases use operation/tier groups.",
        "An asterisk requires at least five rounds and an interval outside 1.",
        "The |log ratio| must also exceed the noise floor and the configured minimum effect.",
        "",
    ]
    text += ["| Variant | Revision |", "|---|---|"]
    for variant, revision in summary["variants"].items():
        text.append(f"| {variant} | {revision} |")
    text.append("")
    table = Table("Target", "Comparison", "Variant", "Operation", "Tier", "Ratio")
    for target, result in summary["targets"].items():
        text += [f"## {target}", ""]
        if "error" in result:
            text += [f"Target failed: {result['error']}", ""]
            continue
        for warning in result.get("warnings", []):
            text += [f"Warning: {warning}", ""]
        text += goal_table(result.get("goals", []))
        text += [f"Minimum effect: {result['minimum_effect']:.4%}.", ""]
        if result["noise_floors"]:
            text += ["| A/A floor group | Noise floor |", "|---|---:|"]
            for group, floor in sorted(result["noise_floors"].items()):
                text.append(f"| {group} | {floor:.4%} |")
        else:
            text.append("A/A is disabled. The report does not mark significance.")
        text += ["", *outlier_table(result.get("outliers", []))]
        text += [
            "| Case | Comparison | Variant | Ratio | 95% CI | Outlier rounds |",
            "|---|---|---|---:|---|---|",
        ]
        for row in result["rows"]:
            mark = " *" if row["significant"] else ""
            lo, hi = row["ci95"]
            text.append(
                f"| {row['case']} | {comparison(row)} | {row['variant']} | "
                f"{row['ratio']:.4f}{mark} | {lo:.4f}-{hi:.4f} | {outlier_cell(row)} |"
            )
        text += [
            "",
            "### Size tiers",
            "",
            "| Comparison | Variant | Operation | Tier | Geomean |",
            "|---|---|---|---|---:|",
        ]
        for row in result["tiers"]:
            values = [
                comparison(row),
                row["variant"],
                row["op"],
                row["tier"],
                f"{row['geomean']:.4f}",
            ]
            table.add_row(target, *values)
            text.append("| " + " | ".join(values) + " |")
        text.append("")
    (path / "report.md").write_text("\n".join(text))
    Console().print(table)


OUTLIER_LIMIT = 50


def outlier_cell(row: dict[str, Any]) -> str:
    flagged = row.get("outlier_rounds", {})
    return " ".join(
        f"{side[0]}:r{index}"
        for side in ("candidate", "baseline")
        for index in flagged.get(side, [])
    )


def outlier_table(outliers: list[dict[str, Any]]) -> list[str]:
    text = ["### Outlier rounds", ""]
    if not outliers:
        return [*text, "No round was flagged.", ""]
    counts: dict[str, int] = {}
    for item in outliers:
        counts[item["variant"]] = counts.get(item["variant"], 0) + 1
    text += [
        "A flagged round departs from the other rounds of its variant, case, and implementation.",
        "It stays in the ratio and leaves the interval. Flagged rounds per variant: "
        + ", ".join(f"{variant} {count}" for variant, count in sorted(counts.items()))
        + ".",
        "",
        "| Variant | Case | Implementation | Round | Ratio to other rounds |",
        "|---|---|---|---:|---:|",
    ]
    ordered = sorted(outliers, key=lambda item: -abs(math.log(item["ratio"])))
    text += [
        f"| {item['variant']} | {item['case']} | {item['impl']} | {item['round']} | "
        f"{item['ratio']:.3f} |"
        for item in ordered[:OUTLIER_LIMIT]
    ]
    if len(ordered) > OUTLIER_LIMIT:
        text.append("")
        text.append(
            f"The largest {OUTLIER_LIMIT} of {len(ordered)} appear. `summary.json` has all."
        )
    return [*text, ""]


def null_note(value: dict[str, Any]) -> str:
    reference = value.get("aa_reference")
    if not reference or not reference["cases"]:
        return ""
    return (
        f", A/A null above {reference['threshold']:g}: "
        f"{reference['violations']}/{reference['cases']}"
    )


def goal_table(goals: list[dict[str, Any]]) -> list[str]:
    text = [
        "### Goals",
        "",
        "| Variant | Operation | Goal | Verdict | Evidence |",
        "|---|---|---|---|---|",
    ]
    for goal in goals:
        for name in ("G2", "G3", "G4"):
            value = goal[name]
            if name == "G2":
                evidence = (
                    f"geomean={value['geomean']}, tiers={value['tier_geomeans']}, "
                    f"significant >1.10: {len(value['significant_above_1_10'])}, "
                    f"cases={value['cases']}/{value['required_cases']}, rounds={value['rounds']}"
                    + null_note(value)
                )
            elif name == "G3":
                evidence = (
                    f"worst={value['worst_ratio']}, "
                    f"significant >1: {len(value['significant_above_1'])}, "
                    f"missing={len(value['missing_cases'])}, rounds={value['rounds']}"
                    + null_note(value)
                )
            else:
                evidence = (
                    f"small={value['small']['status']} (ratio={value['small']['ratio']}), "
                    f"const={value['const']['status']}"
                    f"{null_note(value['const'])}, no-call=NA (checked by binary test, P4)"
                )
            if "reason" in value:
                evidence += ". " + value["reason"]
            text.append(
                f"| {goal['variant']} | {goal['op']} | {name} | {value['status']} | {evidence} |"
            )
    text += ["", "Full goal evidence and missing cases appear in `summary.json`.", ""]
    return text
