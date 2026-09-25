"""Run a baseline x86_64 binary under qemu CPU models with known features.

With `--probe`, the binary is dispatch_probe and each model must select the
expected level. Otherwise the binary is a unit-test binary, and it must pass
on every model. On an x86_64 host without qemu, the binary runs natively
once and the level is only printed.
"""

import argparse
import json
import os
import resource
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "export"))
from runtime import host_arch, linux_runner  # noqa: E402

# qemu TCG implements AVX2 but not AVX-512: models with AVX-512 run with those
# features masked and must fall back to x86_64_v3.
MODELS = {
    "max": "x86_64_v3",
    "Haswell": "x86_64_v3",
    "SapphireRapids": "x86_64_v3",
    "EPYC-Genoa": "x86_64_v3",
    "max,-bmi2": "generic",
    "max,-movbe": "generic",
    "Westmere": "generic",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("binary")
    args = parser.parse_args()
    runner = linux_runner("x86_64")
    if runner is None:
        print(f"SKIP {args.binary}: no x86_64 Linux runner")
        return
    models = MODELS if runner else {None: None}
    for model, expected in models.items():
        command = runner + (["-cpu", model] if model else []) + [args.binary]
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
            # A qemu core dump holds the whole environment.
            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)),
        )
        label = model or host_arch()
        if result.returncode:
            raise SystemExit(f"FAIL {label}: exit {result.returncode}\n{result.stdout}{result.stderr}")
        if args.probe:
            record = json.loads(result.stdout)
            if expected is not None and record["level"] != expected:
                raise SystemExit(f"FAIL {label}: selected {record}, expected {expected}")
            print(f"PASS {label}: {json.dumps(record)}")
        else:
            summary = [line for line in result.stderr.splitlines() if "passed" in line]
            print(f"PASS {label}: {summary[-1] if summary else 'tests passed'}")


if __name__ == "__main__":
    main()
