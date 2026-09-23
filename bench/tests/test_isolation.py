from typing import Any

import pytest

from ec2bench.facts import topology
from ec2bench.isolation import isolate, select_cpu


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("0 0 0 0,2\n1 0 1 1,3\n2 0 0 0,2\n3 0 1 1,3", (1, [0, 2])),
        ("0 0 0 0\n1 0 1 1\n2 0 2 2\n3 0 3 3", (3, [0, 1, 2])),
        ("0 0 0 0\n1 0 1 1\n2 1 0 2\n3 1 1 3", (3, [0, 1, 2])),
    ],
)
def test_select_cpu(text: str, expected: tuple[int, list[int]]) -> None:
    assert select_cpu(topology(text)) == expected


def test_one_core() -> None:
    with pytest.raises(ValueError, match="at least two"):
        select_cpu(topology("0 0 0 0,1\n1 0 0 0,1"))


class FakeBox:
    def __init__(self) -> None:
        self.commands: list[str] = []

    def run(self, command: str) -> str:
        self.commands.append(command)
        return "0-3\n" if "show" in command else ""


def test_restore_after_failure() -> None:
    box: Any = FakeBox()
    with (  # noqa: PT012 — exercise restoration after a body exception
        pytest.raises(RuntimeError, match="measurement failed"),
        isolate(box, topology("0 0 0 0\n1 0 1 1\n2 0 2 2\n3 0 3 3")) as cpu,
    ):
        assert cpu == 3
        raise RuntimeError("measurement failed")
    assert len([command for command in box.commands if "AllowedCPUs=0-3" in command]) == 3
    assert len([command for command in box.commands if "AllowedCPUs=0,1,2" in command]) == 3
