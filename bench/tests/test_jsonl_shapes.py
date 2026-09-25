"""Record shapes that the real bench-fastmem binary emits (schemas v2 and v3)."""

import json
from pathlib import Path

import pytest

from fastmem_bench.jsonl import parse
from tests.conftest import MEMORY, META_V2

META = {
    **META_V2,
    "type": "meta",
    "schema": 2,
    "rev": "x",
    "zig": "0.16.0",
    "target": "aarch64-linux-gnu",
    "cpu": "neoverse_v2",
    "optimize": "ReleaseFast",
    "link_libc": True,
    "chunk_bytes": 16,
    "suite": "standard",
    "seed": 1,
    "samples": 1,
    "sample_ms": 1,
    "warmup_ms": 1,
    "impls": ["fastmem_abi"],
    "perf": {"available": False, "events": ["cycles", "instructions"], "error": "EACCES"},
}
BASE = {
    "type": "sample",
    "impl": "fastmem_abi",
    "sample": 0,
    "iters": 10,
    "ns": 100,
    "cycles": None,
    "instructions": None,
    "ref_cycles": None,
    "time_enabled": None,
    "time_running": None,
}
ROWS = [
    {
        **BASE,
        "case": "copy/aligned/8",
        "op": "copy",
        "profile": "aligned",
        "size": 8,
        "src_off": 0,
        "dst_off": 0,
        "gap": None,
    },
    {
        **BASE,
        "case": "move/fwd-gap1/64",
        "op": "move",
        "profile": "fwd-gap1",
        "size": 64,
        "src_off": 1,
        "dst_off": 0,
        "gap": 1,
    },
    {
        **BASE,
        "case": "copy/dist/small",
        "op": "copy",
        "profile": "dist",
        "size": 85.0,
        "src_off": None,
        "dst_off": None,
        "gap": None,
    },
]


CONST_ROWS = [
    {
        **BASE,
        "impl": impl,
        "case": f"{op}/const/64",
        "op": op,
        "profile": "const",
        "size": 64,
        "src_off": 0,
        "dst_off": 0,
        "gap": None,
    }
    for op in ("copy", "move", "set")
    for impl in ("builtin_const", "fastmem_inline")
]


def write(path: Path, meta: dict, rows: list[dict]) -> Path:
    cases = len({row["case"] for row in rows})
    lines = [meta, *rows, {"type": "end", "cases": cases, "elapsed_ns": 1}]
    path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
    return path


def test_parses_copy_move_and_dist_rows(tmp_path: Path) -> None:
    parsed = parse(write(tmp_path / "r.jsonl", META, ROWS))
    assert len(parsed.samples) == 3
    assert parsed.meta["memory"] is None


def test_v3_parses_memory_and_const_move_and_set(tmp_path: Path) -> None:
    meta = {
        **META,
        "schema": 3,
        "memory": MEMORY,
        "fastmem_set": True,
        "impls": ["fastmem_abi", "fastmem_inline", "builtin_const"],
    }
    rows = [*CONST_ROWS, *({**row, "impl": impl} for row in ROWS for impl in ("fastmem_abi",))]
    rows += [{**row, "impl": "fastmem_inline"} for row in ROWS]
    parsed = parse(write(tmp_path / "r.jsonl", meta, rows))
    assert parsed.meta["memory"]["anon_huge_bytes_start"] == 6 << 20
    assert {row["op"] for row in parsed.samples if row["profile"] == "const"} == {
        "copy",
        "move",
        "set",
    }


@pytest.mark.parametrize(
    "mutation",
    ["v2-const-move", "v3-no-memory", "v2-memory", "memory-offset", "huge-exceeds", "schema-4"],
)
def test_schema_versions_reject_mixed_shapes(tmp_path: Path, mutation: str) -> None:
    meta = {**META, "impls": ["builtin_const", "fastmem_inline"]}
    rows = [row for row in CONST_ROWS if row["op"] != "set"]
    if mutation == "v2-const-move":
        pass
    elif mutation == "v3-no-memory":
        meta["schema"] = 3
    elif mutation == "v2-memory":
        meta["memory"] = MEMORY
    elif mutation == "schema-4":
        meta.update(schema=4, memory=MEMORY)
    else:
        memory = dict(MEMORY)
        if mutation == "memory-offset":
            memory["dst_offset"] = memory["region_bytes"]
        else:
            memory["anon_huge_bytes_end"] = memory["arena_bytes"] + 1
        meta.update(schema=3, memory=memory)
    with pytest.raises(ValueError, match=r"."):
        parse(write(tmp_path / "r.jsonl", meta, rows))
