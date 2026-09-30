"""Mutation tests for the x86 gate with a fleet probe object."""
import contextlib
import io
from pathlib import Path
import re
import runpy
import subprocess
import sys
from unittest.mock import patch

cpu, variant, artifact, *extra = sys.argv[1:]
checker = Path(__file__).with_name("check_codegen.py")
dis = subprocess.check_output(["llvm-objdump", "-dr", "--no-show-raw-insn", artifact], text=True)
nm = subprocess.check_output(["llvm-nm", "--defined-only", "--format=posix", artifact], text=True)
symbols = {f[0]: (int(f[2], 16), int(f[3], 16))
           for line in nm.splitlines() if len(f := line.split()) == 4}
checks = 0


def check(text, requested, failure=None):
    global checks
    checks += 1
    argv = [str(checker), cpu, *requested, artifact, *extra]
    with patch.object(sys, "argv", argv), patch("subprocess.check_output", side_effect=[text, nm]):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                result = runpy.run_path(str(checker), run_name="__main__")
            except SystemExit as error:
                assert failure is not None and failure in str(error), str(error)
            else:
                assert failure is None, f"Gate accepted mutation: {failure}"
                return result


def mutate(old, new, symbol="x86_64.move.copyLarge"):
    start, size = symbols[symbol]
    lines = []
    changed = False
    for line in dis.splitlines():
        match = re.match(r"\s*([0-9a-f]+):", line)
        if match and start <= int(match[1], 16) < start + size and old in line:
            line = line.replace(old, new)
            changed = True
        lines.append(line)
    assert changed, f"Mutation missed {symbol}: {old}"
    return "\n".join(lines)


gate = check(dis, [variant])
pointer_order = gate["tests_pointer_order"]
resolve_policy = gate["resolve_policy"]
for experiment in ("auto", "x86f_pairs", "x86f_chunks", "x86f_source", "x86f_source64",
                   "x86f_temporal", "x86f_zen4", "x86f_dispatch", "x86g_temporal", "x86g_medium"):
    for model in ("sapphirerapids", "graniterapids", "znver4", "znver5", "x86_64_v3", "x86_64_v4"):
        policy = resolve_policy(model, experiment)
        assert policy["entry_pairs"] == (model == "graniterapids")
        assert policy["medium_chunks"] == (model in ("sapphirerapids", "graniterapids"))
        assert policy["medium_entry"] == (model == "graniterapids")
        assert policy["source_64"] == (model == "znver5")
        assert policy["zen4_short"] == (model == "znver4" and experiment == "x86f_zen4")
        if model == "znver4":
            assert policy["nt_min"] == 0xc00001
        elif model == "znver5":
            assert policy["nt_min"] == (0x4000001 if experiment == "x86f_temporal" else 0x2000000)
        else:
            assert policy["nt_min"] == {"sapphirerapids": 0x3580000, "graniterapids": 0xf100000}.get(model)
        checks += 1
for experiment in ("none", "medium_layout", "medium_entry", "small_paths"):
    for model in ("sapphirerapids", "graniterapids", "znver4", "znver5"):
        policy = resolve_policy(model, experiment)
        assert not policy["entry_pairs"] and not policy["medium_chunks"] and not policy["source_64"]
        assert policy["medium_entry"] == (model == "graniterapids" and experiment == "medium_entry")
        checks += 1
assert not pointer_order("leaq -0x4(%rdx), %rdi\nsubq %rcx, %rdi")
assert not pointer_order("movl %edx, %edi\nsubq %rsi, %rdi")
assert pointer_order("cmpq %rsi, %rdi")
assert pointer_order("movq %rdi, %rax\nsubq %rsi, %rax")
assert pointer_order("leaq 0x10(%rsi), %rcx\ncmpq %rdi, %rcx")
check(dis, [], "2")
for wrong in ("entry", "high_regs", "tiered", "compact", "medium_first", "ymm_medium", "straight_1k"):
    if wrong != variant:
        check(dis, [wrong], f"{cpu}:")
if cpu in ("sapphirerapids", "graniterapids"):
    check(mutate("movsb", "nop"), [variant], "copy large path has wrong REP policy")
if cpu in ("znver4", "znver5"):
    threshold = hex(gate["policy"]["nt_min"])
    check(mutate(f"${threshold}, %rdx", "$0x1234567, %rdx"),
          [variant], "copy large thresholds")
if cpu == "znver5":
    check(mutate("$0x10000, %rdx", "$0x100000, %rdx", "x86_64.move.largeKernel"),
          [variant], "move large thresholds")
nt_symbol = "x86_64.ops.streamCopyPages" if cpu == "sapphirerapids" and variant != "entry" else "x86_64.move.copyLarge"
fence_symbol = "x86_64.move.streamPages" if cpu == "sapphirerapids" and variant != "entry" else "x86_64.move.copyLarge"
check(mutate("vmovntdq", "vmovdqa64", nt_symbol), [variant], "copy large path has wrong NT policy")
check(mutate("sfence", "nop", fence_symbol), [variant], "copy large path has wrong NT fence policy")
if cpu == "sapphirerapids" and variant != "entry":
    check(mutate("prefetcht0", "nop", nt_symbol), [variant], "SPR NT tile lacks eight prefetches")
    check(mutate("0x1000(", "0x2000(", nt_symbol), [variant], "SPR NT tile lacks its second page")
check(mutate("%zmm", "%ymm"), [variant], "copy large path lacks %zmm")
if variant == "ymm_medium":
    check(mutate("%ymm", "%zmm", "x86_64.move.kernel"), [variant], "lacks %ymm")
    check(mutate("%ymm", "%zmm", "x86_64.set.kernel"), [variant], "lacks %ymm")
if variant == "straight_1k":
    check(mutate("%zmm31", "%zmm30", "x86_64.move.kernel"), [variant], "1 KiB class")
if variant != "entry":
    check(mutate("0x40(%rsi)", "0x41(%rsi)", "x86_64.move.kernel"), [variant], "wrong source bytes")

if gate["temporal_set_256"] and variant != "entry":
    check(mutate("vmovdqa64", "vmovdqu64", "x86_64.set.largeKernel"),
          [variant], "Zen5 temporal fill must have four aligned stores")
    check(mutate("$0x100,", "$0x200,", "x86_64.set.largeKernel"),
          [variant], "Zen5 temporal fill must advance 256 bytes")
    check(mutate("0xc0(", "0x100(", "x86_64.set.largeKernel"),
          [variant], "Zen5 temporal fill has wrong offsets")
print(f"x86 gate mutation tests ({cpu}/{variant}): {checks} passed")
