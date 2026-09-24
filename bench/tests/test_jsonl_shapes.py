"""Record shapes that the real bench-fastmem binary emits (schema v2)."""

import json
from pathlib import Path

from fastmem_bench.jsonl import parse
from tests.conftest import META_V2

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


def test_parses_copy_move_and_dist_rows(tmp_path: Path) -> None:
    path = tmp_path / "r.jsonl"
    lines = [META, *ROWS, {"type": "end", "cases": 3, "elapsed_ns": 1}]
    path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
    parsed = parse(path)
    assert len(parsed.samples) == 3
