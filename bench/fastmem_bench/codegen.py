"""Inspect fastmem call boundaries without changes to the kernels."""

import hashlib
import re
import subprocess
from pathlib import Path
from typing import Any

MEMORY_SYMBOLS = {"memcpy", "memmove", "memset"}
INLINE_PREFIX = "bench_fastmem.runFastmemInline"


def scan_calls(assembly: str, roots: list[str]) -> list[dict[str, str]]:
    selected = set(roots)
    caller = ""
    calls = []
    for line in assembly.splitlines():
        header = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if header:
            caller = header[1]
            continue
        instruction = re.match(
            r"^\s*([0-9a-f]+):\s+(?:callq?|j[a-z]+|blr?|b(?:\.[a-z]+)?|br|cbn?z|tbn?z)\s+.*<([^>]+)>",
            line,
        )
        if caller not in selected or instruction is None:
            continue
        symbol = re.split(r"[+@]", instruction[2])[0]
        if symbol in MEMORY_SYMBOLS:
            calls.append({"caller": caller, "symbol": symbol, "address": "0x" + instruction[1]})
    return calls


def inspect(binary: Path) -> dict[str, Any]:
    symbols = subprocess.run(
        ["llvm-nm", "--defined-only", str(binary)],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout
    roots = sorted(
        {
            line.split()[-1]
            for line in symbols.splitlines()
            if line.split() and line.split()[-1].startswith(("fastmem_", INLINE_PREFIX))
        }
    )
    if not {"fastmem_copy", "fastmem_move"} <= set(roots) or not any(
        name.startswith(INLINE_PREFIX) for name in roots
    ):
        raise ValueError(f"{binary}: missing ABI or inline roots for the delegation check")
    assembly = subprocess.run(
        [
            "llvm-objdump",
            "-d",
            "--no-show-raw-insn",
            "--disassemble-symbols=" + ",".join(roots),
            str(binary),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    ).stdout
    emitted = set(re.findall(r"^[0-9a-f]+ <(.+)>:$", assembly, re.MULTILINE))
    if not set(roots) <= emitted:
        raise ValueError(f"{binary}: incomplete fastmem disassembly")
    return {
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "checked_roots": roots,
        "delegations": scan_calls(assembly, roots),
    }


def verify_recorded(actual: dict[str, Any], expected: dict[str, Any]) -> None:
    if actual != expected:
        raise ValueError("Raw codegen evidence disagrees with the recorded build")
