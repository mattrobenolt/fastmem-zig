from datetime import timedelta
from pathlib import Path

import pytest

from ec2bench.config import Config, duration, find_root


def test_config(config: Config) -> None:
    assert config.project["name"] == "test-bench"
    assert config.project["extra_key"] == "ignored"
    assert config.targets["intel"]["zig_cpu"] == "sapphirerapids"
    assert config.fleet["default_owner"] == "agent"
    nested = config.root / "deep/inside"
    nested.mkdir(parents=True)
    assert find_root(nested) == config.root
    assert config.select(["arm", "intel", "arm"]) == ["arm", "intel"]
    with pytest.raises(ValueError, match="Unknown targets"):
        config.select(["oops"])


@pytest.mark.parametrize(("text", "expected"), [("4h", 14400), ("2m", 120), ("1d", 86400)])
def test_duration(text: str, expected: int) -> None:
    assert duration(text) == timedelta(seconds=expected)


@pytest.mark.parametrize("text", ["0h", "-1h", "2", "1.5h", "1w", "h", ""])
def test_bad_duration(text: str) -> None:
    with pytest.raises(ValueError, match="Invalid TTL"):
        duration(text)


def test_missing_root(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match=r"No bench\.toml"):
        find_root(tmp_path)


def test_invalid_arch(config: Config) -> None:
    path = config.root / "bench.toml"
    path.write_text(path.read_text().replace('arch = "arm64"', 'arch = "unknown"'))
    with pytest.raises(ValueError, match="Invalid instance_type or arch"):
        Config.load(config.root)
