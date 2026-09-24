"""Reserve the final physical core and restore the original cpuset properties."""

import shlex
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from ec2bench.box import Box
from ec2bench.parallel import check_cancelled

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


def run_isolated(
    box: Box,
    cpu: int,
    command: list[str],
    *,
    unit: str,
    output: str,
    error: str,
    timeout: int = 600,
) -> None:
    """Execute a command outside the restricted SSH slice."""
    check_cancelled()
    args = [
        "systemd-run",
        "--quiet",
        "--wait",
        "--pipe",
        "--collect",
        f"--unit={unit}",
        "--slice=bench.slice",
        f"--property=AllowedCPUs={cpu}",
        f"--property=RuntimeMaxSec={timeout - 60}",
        "--property=TimeoutStopSec=10",
        "taskset",
        "-c",
        str(cpu),
        *command,
    ]
    # Keep the file and forward stderr to SSH so failures include the diagnostic.
    shell = (
        f"{shlex.join(args)} > {shlex.quote(output)} 2> {shlex.quote(error)}; "
        f"status=$?; cat {shlex.quote(error)} >&2; exit $status"
    )
    box.run(shell, timeout=timeout)


@contextmanager
def isolate(box: Box, topology: list[dict[str, Any]]) -> Iterator[int]:
    cpu, housekeeping = select_cpu(topology)
    # The directory is an atomic claim across harness processes. A stale claim fails closed.
    box.run("mkdir /run/ec2bench-isolation.lock 2>/dev/null || { echo 'box busy' >&2; exit 1; }")
    try:
        active = box.run("systemctl list-units --state=active --no-legend 'bench-*'").strip()
        if active:
            raise RuntimeError(f"box busy: {active}")
        old = {
            unit: box.run(f"systemctl show {unit} -p AllowedCPUs --value").strip() for unit in UNITS
        }
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
                        f"systemctl set-property --runtime {unit} "
                        f"{shlex.quote('AllowedCPUs=' + value)}"
                    )
                except Exception as error:  # noqa: BLE001 — attempt all restorations
                    errors.append(f"{unit}: {error}")
            if errors:
                raise RuntimeError("CPU isolation restoration failed: " + "; ".join(errors))
    finally:
        box.run("rmdir /run/ec2bench-isolation.lock")
