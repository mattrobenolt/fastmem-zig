import copy
import json
from pathlib import Path

import pytest

from fastmem_bench.analysis import analyze
from fastmem_bench.codegen import scan_calls, verify_recorded
from fastmem_bench.goals import evaluate
from tests.conftest import CODEGEN, measurement
from tests.test_v2 import complete_rows


def test_scan_abi_and_inline_calls_without_builtin_false_positives() -> None:
    # Synthetic caller disassembly, not memory-library implementation code.
    assembly = """
00001000 <fastmem_copy>:
    1000: b 0x2000 <memcpy>
00001100 <fastmem_move>:
    1100: callq 0x2100 <memmove@plt>
00001200 <bench_fastmem.runFastmemInline__test>:
    1200: jmp 0x2200 <memset>
    1204: bl 0x2300 <clock_gettime>
00001300 <builtin_memcpy>:
    1300: b 0x2000 <memcpy>
00001400 <bench_fastmem.runLoop__builtin>:
    1400: callq 0x2000 <memcpy>
"""
    calls = scan_calls(assembly, CODEGEN["checked_roots"])
    assert [call["symbol"] for call in calls] == ["memcpy", "memmove", "memset"]
    assert [call["address"] for call in calls] == ["0x1000", "0x1100", "0x1200"]


def test_delegation_invalidates_g2_g3_for_the_target_variant() -> None:
    codegen = copy.deepcopy(CODEGEN)
    codegen["delegations"] = [
        {"caller": "fastmem_copy", "symbol": "memcpy", "address": "0x1000"},
    ]
    goals = evaluate(complete_rows(), ["v0"], codegen={"v0": codegen})
    for goal in goals:
        for name in ("G2", "G3"):
            assert goal[name]["status"] == "INVALID"
            assert goal[name]["reason"] == "fastmem delegates to memcpy"
    clean = evaluate(complete_rows(), ["v0"], codegen={"v0": CODEGEN})
    assert clean[0]["G2"]["status"] == "PASS"
    unchecked = evaluate(complete_rows(), ["v0"])
    assert unchecked[0]["G2"]["status"] == "NA"
    assert "no codegen evidence" in unchecked[0]["G2"]["reason"]


def test_raw_codegen_survives_analysis_and_detects_round_mismatch(tmp_path: Path) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            path = tmp_path / variant / f"r{index}.jsonl"
            measurement(path)
            records = [json.loads(line) for line in path.read_text().splitlines()]
            records[0]["codegen"]["delegations"] = [
                {"caller": "fastmem_move", "symbol": "memmove", "address": "0x1100"},
            ]
            path.write_text("\n".join(map(json.dumps, records)))
    result = analyze(tmp_path, ["v0"], "v0")
    assert result["goals"][0]["G2"]["status"] == "INVALID"
    assert result["codegen"]["v0"]["delegations"][0]["symbol"] == "memmove"
    with pytest.raises(ValueError, match="disagrees"):
        verify_recorded(result["codegen"], {"v0": CODEGEN, "aa": CODEGEN})
    measurement(tmp_path / "v0/r4.jsonl")
    with pytest.raises(ValueError, match="Codegen evidence changed within"):
        analyze(tmp_path, ["v0"], "v0")
