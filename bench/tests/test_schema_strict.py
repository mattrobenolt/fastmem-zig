import json
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.jsonl import parse_text
from tests.conftest import measurement


@pytest.mark.parametrize(
    ("index", "field", "value"),
    [
        (0, "extra", 1),
        (1, "extra", 1),
        (-1, "extra", 1),
        (0, "schema", 2.0),
        (0, "chunk_bytes", 7),
        (0, "chunk_bytes", 16.0),
        (0, "samples", True),
        (0, "samples", "2"),
        (0, "sample_ms", 1.5),
        (0, "link_libc", 1),
        (0, "link_libc", False),
        (1, "src_off", None),
        (1, "dst_off", None),
        (1, "gap", 1),
        (1, "src_off", True),
        (1, "size", 32),
        (1, "ns", 1.5),
        (1, "ns", 100.0),
        (1, "ns", "100"),
        (1, "iters", 1.0),
        (1, "size", True),
        (1, "case", "copy/aligned/64/extra"),
        (1, "dst_off", 3),
        (1, "profile", "unknown"),
        (-1, "cases", 1.0),
    ],
)
def test_rejects_incoherent_or_coerced_records(
    tmp_path: Path,
    index: int,
    field: str,
    value: Any,
) -> None:
    path = tmp_path / "r.jsonl"
    measurement(path)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    records[index][field] = value
    with pytest.raises(ValueError, match=r"."):
        parse_text("\n".join(map(json.dumps, records)))


@pytest.mark.parametrize("mutation", ["duplicate", "nested-extra", "partial-perf", "wrong-suite"])
def test_rejects_nested_and_cross_field_errors(tmp_path: Path, mutation: str) -> None:
    path = tmp_path / "r.jsonl"
    measurement(path)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    if mutation == "nested-extra":
        records[0]["resolution"]["memcpy"]["glibc"]["extra"] = 1
    elif mutation == "partial-perf":
        records[1]["instructions"] = 10
    elif mutation == "wrong-suite":
        records[0]["suite"] = "dist"
    text = "\n".join(map(json.dumps, records))
    if mutation == "duplicate":
        text = text.replace('"schema": 2', '"schema": 1, "schema": 2')
    with pytest.raises(ValueError, match=r"."):
        parse_text(text)


def test_ref_cycles_fallback_retains_primary_counts(tmp_path: Path) -> None:
    path = tmp_path / "r.jsonl"
    measurement(path)
    records = [json.loads(line) for line in path.read_text().splitlines()]
    records[0]["perf"] = {
        "available": True,
        "events": ["cycles", "instructions"],
        "error": "perf_event_open(ref-cycles): NOENT",
    }
    for row in records[1:-1]:
        row.update(cycles=100, instructions=200, time_enabled=1000, time_running=900)
    parse_text("\n".join(map(json.dumps, records)))
    records[1]["ref_cycles"] = 100
    with pytest.raises(ValueError, match="Ref-cycles disagree"):
        parse_text("\n".join(map(json.dumps, records)))
