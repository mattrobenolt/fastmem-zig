"""Reserve the final physical core and restore the original cpuset properties."""

import shlex
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from ec2bench.box import Box

UNITS = ("system.slice", "user.slice", "init.scope")


def select_cpu(topology: list[dict[str, Any]]) -> tuple[int, list[int]]:
    cores: dict[tuple[int, int], list[int]] = {}
    for item in topology:
        cores.setdefault((item["package"], item["core"]), []).append(item["cpu"])
    if len(cores) < 2:
        raise ValueError("CPU isolation requires at least two physical cores")
    reserved = cores[max(cores)]
    housekeeping = sorted(item["cpu"] for item in topology if item["cpu"] not in reserved)
    return min(reserved), housekeeping


@contextmanager
def isolate(box: Box, topology: list[dict[str, Any]]) -> Iterator[int]:
    cpu, housekeeping = select_cpu(topology)
    old = {unit: box.run(f"systemctl show {unit} -p AllowedCPUs --value").strip() for unit in UNITS}
    cpus = ",".join(map(str, housekeeping))
    try:
        for unit in UNITS:
            box.run(f"systemctl set-property --runtime {unit} AllowedCPUs={cpus}")
        yield cpu
    finally:
        errors = []
        for unit, value in old.items():
            try:
                box.run(
                    f"systemctl set-property --runtime {unit} {shlex.quote('AllowedCPUs=' + value)}"
                )
            except Exception as error:  # noqa: BLE001 — attempt all restorations
                errors.append(f"{unit}: {error}")
        if errors:
            raise RuntimeError("CPU isolation restoration failed: " + "; ".join(errors))
