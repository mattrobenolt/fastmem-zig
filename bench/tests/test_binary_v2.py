"""Native integration tests. Build with `zig build` before this module runs."""

import json
import re
import subprocess
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.codegen import inspect
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
    assert measurement.end["cases"] == 120
    assert measurement.meta["samples"] == 4
    assert any(
        row["profile"] == "page-offset" and row["src_off"] == 0 and row["dst_off"] == 2048
        for row in measurement.samples
    )
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
    assert records[-1]["cases"] == 514
    cases = {row["case"] for row in records[1:-1]}
    assert {
        "copy/const/256",
        "move/dist/small",
        "set/dist/mixed",
        "move/fwd-gap4096/65536",
        "move/fwd-half/65536",
    } <= cases
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
            "--source",
            "--disassemble-symbols=" + ",".join(loops),
            str(BINARY),
        ],
        text=True,
    )
    # The C function pointer path remains indirect after ReleaseFast optimization.
    call_sites = disassembly.split("function(dst, src, len);")[1:]
    assert call_sites
    for site in call_sites:
        # Clock callbacks also use indirect calls. Match only the memory operation site.
        instructions = "\n".join(site.splitlines()[:6])
        assert re.search(r"\bblr\s+x\d+|\bcallq?\s+\*", instructions)


def test_native_codegen_evidence_is_bound_to_the_executable(tmp_path: Path) -> None:
    evidence = inspect(BINARY)
    sidecar = tmp_path / "codegen.json"
    sidecar.write_text(json.dumps(evidence))
    args = (
        "--suite",
        "quick",
        "--filter",
        "copy/aligned/8",
        "--sample-ms",
        "1",
        "--warmup-ms",
        "0",
        "--codegen-file",
        str(sidecar),
    )
    result = invoke(*args)
    assert result.returncode == 0, result.stderr
    assert parse_text(result.stdout).meta["codegen"] == evidence
    evidence["binary_sha256"] = "0" * 64
    sidecar.write_text(json.dumps(evidence))
    result = invoke(*args)
    assert result.returncode != 0
    assert "CodegenEvidenceDoesNotMatchExecutable" in result.stderr
    assert not result.stdout


def test_native_large_forward_gap_profiles() -> None:
    for profile, gap in (("fwd-gap4096", 4096), ("fwd-half", 32768)):
        result = invoke(
            "--suite",
            "standard",
            "--filter",
            f"move/{profile}/65536",
            "--sample-ms",
            "1",
            "--warmup-ms",
            "0",
        )
        assert result.returncode == 0, result.stderr
        measurement = parse_text(result.stdout)
        assert {(row["src_off"], row["dst_off"], row["gap"]) for row in measurement.samples} == {
            (gap, 0, gap)
        }
