import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from ec2bench.config import Config
from fastmem_bench.analysis import analyze
from fastmem_bench.build import Build, Source
from fastmem_bench.protocol import execute, orders
from tests.conftest import measurement


class FakeBox:
    instance_id = "i-fake"

    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.commands: list[str] = []
        self.uploads: list[tuple[Path, str]] = []
        self.downloaded = False

    def run(self, command: str, **_kwargs: Any) -> str:
        self.commands.append(command)
        if command.endswith("/libc-probe"):
            return json.dumps(
                {
                    "libc_path": "/nix/store/libc/lib/libc.so.6",
                    "glibc_version": "2.42",
                    "symbols": {
                        name: {"address": "0x70001000", "offset": "0x1000", "symbol": None}
                        for name in ("memcpy", "memmove")
                    },
                }
            )
        if command.startswith("systemd-run") and self.fail:
            raise subprocess.CalledProcessError(1, command)
        if command.startswith("systemctl show"):
            return "0-3\n"
        return ""

    def upload(self, source: Path, destination: str) -> None:
        self.uploads.append((source, destination))

    def download(self, _source: str, destination: Path) -> None:
        self.downloaded = True
        for variant in ("v0", "aa"):
            for index in range(2):
                folder = (
                    destination
                    if destination.name in {"v0", "aa"}
                    else destination / "raw" / variant
                )
                measurement(folder / f"r{index}.jsonl")


def setup(config: Config) -> tuple[Path, Build]:
    facts = config.root / "bench-results/.facts/i-fake.json"
    facts.parent.mkdir(parents=True)
    facts.write_text(
        json.dumps(
            {
                "instance_id": "i-fake",
                "topology": [
                    {"cpu": index, "package": 0, "core": index, "siblings": str(index)}
                    for index in range(4)
                ],
            }
        )
    )
    path = config.root / "bench-results/20260923T120000Z-test"
    path.mkdir(parents=True)
    source = Source("v0", "WORKTREE", config.root, "sourcehash")
    return path, Build(source, "intel", config.root / "prefix", "buildhash")


def test_protocol(config: Config) -> None:
    path, build = setup(config)
    box: Any = FakeBox()
    schedule = orders(["v0", "aa"], 2, 42)
    result = execute(config, box, [build], path, suite="quick", schedule=schedule, aa=True, seed=42)
    assert result["cpu"] == 3
    assert result["warnings"] == []
    commands = [command for command in box.commands if command.startswith("systemd-run")]
    assert len(commands) == 4
    assert all("--slice=bench.slice" in command for command in commands)
    assert all("taskset -c 3" in command for command in commands)
    assert all("/bin/v0/bench-fastmem" in command for command in commands)
    assert all("--seed 42" in command for command in commands)
    assert any(
        "objdump -d --start-address=4096 --stop-address=8192" in command for command in box.commands
    )
    assert len([command for command in box.commands if "AllowedCPUs=0-3" in command]) == 3
    assert box.downloaded
    assert analyze(path / "intel/raw", ["v0"], "v0")["noise_floors"]["copy/size/64"] == 0


def test_protocol_restores_and_downloads_after_failure(config: Config) -> None:
    path, build = setup(config)
    box: Any = FakeBox(fail=True)
    with pytest.raises(subprocess.CalledProcessError):
        execute(config, box, [build], path, suite="quick", schedule=[["v0"]], aa=False, seed=42)
    assert box.downloaded
    assert len([command for command in box.commands if "AllowedCPUs=0-3" in command]) == 3
