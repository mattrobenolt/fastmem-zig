"""Link two fastmem package copies into one baseline x86_64 executable.

Each copy is a separate package instance. Their x86 dispatch symbols carry
different instance ids (build.zig `instanceId`), so the link succeeds. The
check copies the package twice, builds src/export/two_packages/ against the
copies, inspects the symbols, and runs the executable when a runner exists.
"""

import argparse
import re
import resource
import shutil
import subprocess
import zlib
from pathlib import Path

from runtime import linux_runner

# A Zig 0.16 fingerprint is the CRC-32 of the package name (high half) and a
# nonzero id (low half).
FINGERPRINT = hex(zlib.crc32(b"two_packages") << 32 | 0x7F0E5A11)
ZON = """.{{
    .name = .two_packages,
    .version = "0.0.0",
    .fingerprint = {fingerprint},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{{
        .fastmem_a = .{{ .path = "../a" }},
        .fastmem_b = .{{ .path = "../b" }},
    }},
    .paths = .{{""}},
}}
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("zig")
    parser.add_argument("root")
    parser.add_argument("work")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    work = Path(args.work).resolve()
    for copy in ("a", "b"):
        target = work / copy
        shutil.rmtree(target, ignore_errors=True)
        target.mkdir(parents=True)
        for name in ("build.zig", "build.zig.zon"):
            shutil.copy2(root / name, target / name)
        shutil.copytree(root / "src", target / "src")
    consumer = work / "consumer"
    shutil.rmtree(consumer / "src", ignore_errors=True)
    shutil.copytree(root / "src/export/two_packages", consumer, dirs_exist_ok=True)
    (consumer / "build.zig.zon").write_text(ZON.format(fingerprint=FINGERPRINT))
    subprocess.run(
        [
            args.zig,
            "build",
            "-Dtarget=x86_64-linux-musl",
            "-Dcpu=baseline",
            "-Doptimize=ReleaseFast",
        ],
        cwd=consumer,
        check=True,
        timeout=1200,
    )
    binary = consumer / "zig-out/bin/two-packages"
    symbols = subprocess.check_output(["llvm-nm", "--defined-only", str(binary)], text=True)
    instances = set(re.findall(r"\bfastmem_x86_([0-9a-f]{16})_resolve_memcpy$", symbols, re.M))
    assert len(instances) == 2, ("expected two dispatch instances", instances)
    for instance in instances:
        levels = re.findall(rf"\bfastmem_x86_{instance}_(\w+)_memmove$", symbols, re.M)
        assert len(levels) == 8, (instance, levels)  # six levels, resolve, generic
    ran = "static checks only"
    runner = linux_runner("x86_64")
    if runner is not None:
        result = subprocess.run(
            [*runner, str(binary)],
            capture_output=True,
            text=True,
            timeout=300,
            check=True,
            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)),
        )
        ran = f"runtime level {result.stdout.strip()}"
    print(f"PASS two fastmem package instances in one link: {sorted(instances)}, {ran}")


if __name__ == "__main__":
    main()
