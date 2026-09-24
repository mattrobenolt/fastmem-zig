"""Native integration tests. Build with `zig build` before this module runs."""

import json
import re
import subprocess
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.jsonl import parse_text, verify_probe

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "zig-out/bin/bench-fastmem"
PROBE = ROOT / "zig-out/bin/libc-probe"
pytestmark = pytest.mark.skipif(not BINARY.exists(), reason="Run zig build for native binary tests")


def invoke(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(BINARY), *args],
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )


def test_native_quick_resolution_and_balance() -> None:
    result = invoke("--suite", "quick", "--sample-ms", "1", "--warmup-ms", "0")
    assert result.returncode == 0, result.stderr
    measurement = parse_text(result.stdout)
    probe = json.loads(subprocess.check_output([str(PROBE)], text=True))
    verify_probe(measurement, probe)
    assert measurement.end["cases"] == 96
    assert measurement.meta["samples"] == 4
    rows = measurement.samples
    for case in {row["case"] for row in rows}:
        selected = [row for row in rows if row["case"] == case]
        orders = [
            [row["impl"] for row in selected if row["sample"] == sample] for sample in range(4)
        ]
        for sample, order in enumerate(orders):
            rotation = sample % len(order)
            assert order == orders[0][rotation:] + orders[0][:rotation]
    if measurement.meta["perf"]["available"]:
        assert all(row["instructions"] > 0 for row in rows if row["time_running"] > 0)


@pytest.mark.parametrize("suite", ["const", "dist"])
def test_native_const_and_distributions(suite: str) -> None:
    result = invoke("--suite", suite, "--sample-ms", "1", "--warmup-ms", "0")
    assert result.returncode == 0, result.stderr
    measurement = parse_text(result.stdout)
    assert measurement.end["cases"] == (13 if suite == "const" else 6)
    if suite == "const":
        assert {row["impl"] for row in measurement.samples} == {"builtin_const", "fastmem_inline"}
    else:
        assert {row["op"] for row in measurement.samples} == {"copy", "move", "set"}


def test_native_histogram_and_standard_coverage(tmp_path: Path) -> None:
    histogram = tmp_path / "hist.json"
    histogram.write_text('{"24": 100}')
    result = invoke(
        "--suite", "dist", "--dist-file", str(histogram), "--sample-ms", "1", "--warmup-ms", "0"
    )
    assert result.returncode == 0, result.stderr
    measurement = parse_text(result.stdout)
    assert {row["size"] for row in measurement.samples} == {24}
    result = invoke("--suite", "standard", "--list")
    records: list[dict[str, Any]] = [json.loads(line) for line in result.stdout.splitlines()]
    assert records[-1]["cases"] == 415
    cases = {row["case"] for row in records[1:-1]}
    assert {"copy/const/256", "move/dist/small", "set/dist/mixed"} <= cases
    result = invoke("--suite", "large", "--list")
    records = [json.loads(line) for line in result.stdout.splitlines()]
    assert {row["size"] for row in records[1:-1]} == {1 << 20, 4 << 20, 16 << 20, 64 << 20}


@pytest.mark.parametrize("histogram", ["{}", '{"24": -1}', '{"1073741825": 1}', '{"24": "bad"}'])
def test_native_rejects_invalid_histogram(tmp_path: Path, histogram: str) -> None:
    path = tmp_path / "hist.json"
    path.write_text(histogram)
    result = invoke("--suite", "dist", "--dist-file", str(path))
    assert result.returncode != 0
    assert "No complete measurement was produced" in result.stderr
    assert not result.stdout


def test_native_shared_indirect_loop_and_compiler_rt() -> None:
    symbols = subprocess.check_output(["llvm-nm", str(BINARY)], text=True)
    wrappers = subprocess.check_output(
        [
            "llvm-objdump",
            "-d",
            "--disassemble-symbols=builtin_memcpy,builtin_memmove,builtin_memset",
            str(BINARY),
        ],
        text=True,
    )
    for name in ("memcpy", "memmove", "memset"):
        # A local text symbol cannot be the libc PLT entry.
        assert re.search(rf"^[0-9a-f]+ t {name}$", symbols, re.MULTILINE)
        assert f"<{name}>" in wrappers
        assert f"<{name}@plt>" not in wrappers
    loops = [line.split()[-1] for line in symbols.splitlines() if "bench_fastmem.runLoop" in line]
    disassembly = subprocess.check_output(
        [
            "llvm-objdump",
            "-d",
            "--disassemble-symbols=" + ",".join(loops),
            str(BINARY),
        ],
        text=True,
    )
    # The C function pointer path remains indirect after ReleaseFast optimization.
    assert re.search(r"\bblr\s+x\d+|\bcallq?\s+\*", disassembly)
