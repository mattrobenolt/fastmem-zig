import json
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest
from click.testing import CliRunner

from ec2bench.config import Config
from ec2bench.parallel import Outcome
from fastmem_bench.build import Build, Source
from fastmem_bench.runner import run
from tests.conftest import measurement
from tests.test_protocol import FakeBox, setup


def test_run_up_partial_success_and_passthrough(
    config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = Source("v0", "WORKTREE", config.root, "hash")
    build = Build(source, "intel", config.root / "prefix", "key")
    fleet = Mock()
    fleet.one.return_value = {"InstanceId": "i-test"}
    monkeypatch.setattr("fastmem_bench.runner.Fleet", Mock(return_value=fleet))
    monkeypatch.setattr(
        "fastmem_bench.runner.ensure_up",
        Mock(
            return_value={
                "intel": Outcome(value="i-test"),
                "arm": Outcome(error=TimeoutError("image missing")),
            }
        ),
    )
    monkeypatch.setattr("fastmem_bench.runner.resolve", Mock(return_value=[source]))
    builder = Mock(return_value={"v0/intel": Outcome(value=build)})
    monkeypatch.setattr("fastmem_bench.runner.build_all", builder)
    monkeypatch.setattr("fastmem_bench.runner.disassemble", Mock(return_value=None))
    monkeypatch.setattr("fastmem_bench.runner.box_for", Mock(return_value=Mock()))
    monkeypatch.setattr("ec2bench.runs.git", Mock(return_value="fixture"))
    captured = {}

    def execute(
        _config: Config, _box: Any, _builds: Any, path: Path, **kwargs: Any
    ) -> dict[str, Any]:
        captured.update(kwargs)
        for variant in ("v0", "aa"):
            for index in range(5):
                measurement(path / "intel/raw" / variant / f"r{index}.jsonl")
        return {"warnings": []}

    monkeypatch.setattr("fastmem_bench.runner.execute", execute)
    result = CliRunner().invoke(
        run,
        [
            "--up",
            "--label",
            "partial",
            "--filter",
            "aligned",
            "--impl",
            "fastmem,libc",
            "--samples",
            "2",
            "--sample-ms",
            "1",
            "--minimum-effect",
            "0.005",
        ],
        obj=config,
    )
    assert result.exit_code == 1, result.output
    fleet.reap.assert_called_once()
    assert builder.call_args.args[2] == ["intel"]
    assert captured["binary_args"] == [
        "--filter",
        "aligned",
        "--impl",
        "fastmem,libc",
        "--samples",
        "2",
        "--sample-ms",
        "1",
    ]
    path = next(config.results_dir.glob("*-partial"))
    summary = json.loads((path / "summary.json").read_text())
    assert summary["targets"]["arm"]["error"] == "image missing"
    assert summary["targets"]["intel"]["minimum_effect"] == 0.005
    manifest = json.loads((path / "manifest.json").read_text())
    assert manifest["schedule_method"] == "seeded-balanced-latin-square"
    assert manifest["schedule"] == captured["schedule"]
    assert manifest["binary_args"] == captured["binary_args"]


def test_early_parse_failure_stops_remaining_rounds(config: Config) -> None:
    from fastmem_bench.protocol import execute

    path, build = setup(config)
    box: Any = FakeBox()
    downloads = 0

    def download(_source: str, destination: Path) -> None:
        nonlocal downloads
        downloads += 1
        if destination.name == "v0":
            measurement(destination / "r0.jsonl")
            file = destination / "r0.jsonl"
            file.write_text("\n".join(file.read_text().splitlines()[:-1]))

    box.download = download
    with pytest.raises(ValueError, match="no end record"):
        execute(
            config,
            box,
            [build],
            path,
            suite="quick",
            schedule=[["v0"], ["v0"]],
            aa=False,
            seed=1,
            binary_args=["--samples", "1", "--filter", "fwd gap"],
        )
    commands = [cmd for cmd in box.commands if cmd.startswith("systemd-run")]
    assert len(commands) == 1
    assert "--samples 1 --filter 'fwd gap'" in commands[0]
    assert "cat " in commands[0]
    assert downloads == 2
    assert any(cmd.startswith("systemctl stop") for cmd in box.commands)
