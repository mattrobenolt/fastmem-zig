"""Select a runner for Linux ELF probes without a host-format assumption."""

import platform
import shutil


def host_arch():
    machine = platform.machine()
    return {"arm64": "aarch64", "AMD64": "x86_64"}.get(machine, machine)


def linux_runner(arch):
    if platform.system() != "Linux":
        return None
    if host_arch() == arch:
        return []
    qemu = shutil.which("qemu-" + arch)
    return [qemu] if qemu else None
