"""Issue #1: the generic memset must not reach a byte-store loop.

The object comes from the generic fallback on x86_64 baseline (no AVX2). Every
size class stores overlapping head and tail pieces; only the 1..3 byte class
uses byte stores, and it uses exactly three.
"""

import re
import subprocess
import sys

obj = sys.argv[1]
text = subprocess.check_output(
    ["llvm-objdump", "-d", "--no-show-raw-insn", "--disassemble-symbols=root.abi.memsetGeneric,root.setBytes", obj], text=True
)
byte_stores = [line for line in text.splitlines() if re.search(r"\b(movb|sb|strb)\b", line)]
assert text.count("\n") > 10, text
assert len(byte_stores) <= 3, "\n".join(byte_stores)
print(f"PASS {obj}: generic memset has {len(byte_stores)} byte stores (the 1..3 class)")
