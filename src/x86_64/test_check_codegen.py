"""Mutation tests for the x86 gate with an Intel probe object."""
import contextlib
import io
from pathlib import Path
import re
import runpy
import subprocess
import sys
from unittest.mock import patch

cpu, variant, artifact = sys.argv[1:]
checker = Path(__file__).with_name("check_codegen.py")
dis = subprocess.check_output(["llvm-objdump", "-dr", "--no-show-raw-insn", artifact], text=True)
nm = subprocess.check_output(["llvm-nm", "--defined-only", "--format=posix", artifact], text=True)
symbols = {f[0]: (int(f[2], 16), int(f[3], 16))
           for line in nm.splitlines() if len(f := line.split()) == 4}
checks = 0


def check(text, requested, failure=None):
    global checks
    checks += 1
    argv = [str(checker), cpu, *requested, artifact]
    with patch.object(sys, "argv", argv), patch("subprocess.check_output", side_effect=[text, nm]):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                runpy.run_path(str(checker), run_name="__main__")
            except SystemExit as error:
                assert failure is not None and failure in str(error), str(error)
            else:
                assert failure is None, f"Gate accepted mutation: {failure}"


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


check(dis, [variant])
check(dis, [], "2")
for wrong in ("entry", "high_regs", "tiered", "compact", "medium_first", "ymm_medium", "straight_1k"):
    if wrong != variant:
        check(dis, [wrong], f"{cpu}:")
check(mutate("movsb", "nop"), [variant], "copy large path has wrong REP policy")
check(mutate("vmovntdq", "vmovdqa64"), [variant], "copy large path has wrong NT policy")
check(mutate("sfence", "nop"), [variant], "copy large path has wrong NT fence policy")
check(mutate("%zmm", "%ymm"), [variant], "copy large path lacks %zmm")
if variant == "ymm_medium":
    check(mutate("%ymm", "%zmm", "x86_64.move.kernel"), [variant], "lacks %ymm")
    check(mutate("%ymm", "%zmm", "x86_64.set.kernel"), [variant], "lacks %ymm")
if variant == "straight_1k":
    check(mutate("%zmm31", "%zmm30", "x86_64.move.kernel"), [variant], "1 KiB class")
print(f"x86 gate mutation tests ({cpu}/{variant}): {checks} passed")
