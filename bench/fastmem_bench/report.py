"""Machine-readable results and compact human reports."""

import json
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def comparison(row: dict[str, Any]) -> str:
    return f"A/A ({row['candidate_impl']})" if row["comparison"] == "A/A" else row["comparison"]


def write(path: Path, summary: dict[str, Any]) -> None:
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    text = [
        "# Benchmark report",
        "",
        "Ratios below 1 indicate a faster candidate.",
        "",
        "The confidence interval uses a paired bootstrap over rounds.",
        "Each operation/size floor pools A/A departures across profiles and implementations.",
        "The floor includes confidence interval endpoints.",
        "Distribution cases use operation/tier floors.",
        "An asterisk requires at least five rounds and an interval outside 1.",
        "The ratio must also exceed the noise floor and the configured minimum effect.",
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
        text += [f"Minimum effect: {result['minimum_effect']:.4%}.", ""]
        if result["noise_floors"]:
            text += ["| A/A floor group | Noise floor |", "|---|---:|"]
            for group, floor in sorted(result["noise_floors"].items()):
                text.append(f"| {group} | {floor:.4%} |")
        else:
            text.append("A/A is disabled. The report does not mark significance.")
        text += [
            "",
            "| Case | Comparison | Variant | Ratio | 95% CI |",
            "|---|---|---|---:|---|",
        ]
        for row in result["rows"]:
            mark = " *" if row["significant"] else ""
            lo, hi = row["ci95"]
            text.append(
                f"| {row['case']} | {comparison(row)} | {row['variant']} | "
                f"{row['ratio']:.4f}{mark} | {lo:.4f}-{hi:.4f} |"
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
