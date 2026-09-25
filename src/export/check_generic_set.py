"""Issue #1: the generic memset must not reach a byte-store loop.

The object comes from x86_64 baseline (no AVX2). There the generic memset is
the `generic` level of the runtime dispatch (docs/runtime-dispatch.md). Every
size class stores overlapping head and tail pieces; only the 1..3 byte class
uses byte stores, and it uses exactly three.
"""

import re
import subprocess
import sys

obj = sys.argv[1]
defined = set(subprocess.check_output(["llvm-nm", "--defined-only", "-j", obj], text=True).split())
wanted = [s for s in ("fastmem_x86_generic_memset", "generic.memset", "generic.setBytes") if s in defined]
assert wanted, "no generic memset symbol"
text = subprocess.check_output(
    ["llvm-objdump", "-d", "--no-show-raw-insn", "--disassemble-symbols=" + ",".join(wanted), obj], text=True
)
byte_stores = [line for line in text.splitlines() if re.search(r"\b(movb|sb|strb)\b", line)]
assert text.count("\n") > 10, text
assert len(byte_stores) <= 3, "\n".join(byte_stores)
print(f"PASS {obj}: generic memset has {len(byte_stores)} byte stores (the 1..3 class)")
