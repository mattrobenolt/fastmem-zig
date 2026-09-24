"""Check linkage before LLD localizes hidden definitions in the final link."""

import re
import subprocess
import sys

binary = sys.argv[1]
text = subprocess.check_output(["llvm-readelf", "-sW", binary], text=True)
for op in ("memcpy", "memmove", "memset"):
    assert re.search(r"FUNC\s+GLOBAL\s+HIDDEN\s+\d+\s+" + op + r"$", text, re.M), (op, text)
print(f"PASS {binary}: all three definitions are GLOBAL HIDDEN, not WEAK")
