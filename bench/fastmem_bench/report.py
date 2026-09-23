"""Machine-readable results and compact human reports."""

import json
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def write(path: Path, summary: dict[str, Any]) -> None:
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    text = [
        "# Benchmark report",
        "",
        "Ratios below 1 indicate a faster candidate.",
        "",
        "The confidence interval uses a paired bootstrap over rounds.",
        "The target noise floor is the largest A/A ratio or interval departure from 1.",
        "An asterisk marks an interval outside 1 and a ratio beyond that floor.",
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
        floor = result["noise_floor"]
        text += [
            f"A/A noise floor: {floor:.4%}."
            if floor is not None
            else "A/A is disabled. The report does not mark significance.",
            "",
            "| Case | Comparison | Variant | Ratio | 95% CI |",
            "|---|---|---|---:|---|",
        ]
        for row in result["rows"]:
            mark = " *" if row["significant"] else ""
            lo, hi = row["ci95"]
            text.append(
                f"| {row['case']} | {row['comparison']} | {row['variant']} | "
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
                row["comparison"],
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
