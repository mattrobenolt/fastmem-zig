"""Schema-v1 fixtures and project configuration."""

import json
from pathlib import Path
from typing import Any

import pytest

from ec2bench.config import Config


@pytest.fixture
def config(tmp_path: Path) -> Config:
    (tmp_path / "bench.toml").write_text("""
[project]
name = "test-bench"
region = "us-west-2"
profile = "unused"
adapter = "test_adapter"
remote_dir = "/root/bench"
image_version = "1"
extra_key = "ignored"
[fleet]
default_ttl = "4h"
[targets.intel]
instance_type = "c7i.xlarge"
arch = "x86_64"
zig_cpu = "sapphirerapids"
[targets.arm]
instance_type = "c8g.xlarge"
arch = "arm64"
zig_cpu = "neoverse_v2"
""")
    return Config.load(tmp_path)


def measurement(path: Path, scale: float = 1.0, *, size: int = 64) -> None:
    records: list[dict[str, Any]] = [
        {
            "type": "meta",
            "schema": 1,
            "rev": "fixture",
            "zig": "0.16.0",
            "target": "x86_64-linux-gnu",
            "cpu": "sapphirerapids",
            "optimize": "ReleaseFast",
            "link_libc": True,
            "chunk_bytes": 32,
            "suite": "quick",
            "seed": 1,
            "samples": 2,
            "sample_ms": 20,
            "warmup_ms": 10,
            "impls": ["builtin", "fastmem", "libc"],
            "perf": {"available": False, "events": [], "error": "fixture"},
        }
    ]
    for implementation, factor in (("builtin", 2), ("fastmem", 1), ("libc", 1.25)):
        for index in range(2):
            records.append(  # noqa: PERF401 — fixture records stay explicit
                {
                    "type": "sample",
                    "case": f"copy/aligned/{size}",
                    "op": "copy",
                    "profile": "aligned",
                    "size": size,
                    "src_off": 0,
                    "dst_off": 0,
                    "gap": None,
                    "impl": implementation,
                    "sample": index,
                    "iters": 100,
                    "ns": 1000 * factor * scale,
                    "cycles": None,
                    "instructions": None,
                    "ref_cycles": None,
                }
            )
    records.append({"type": "end", "cases": 1, "elapsed_ns": 10000})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n")
