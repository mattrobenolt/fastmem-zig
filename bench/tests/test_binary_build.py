import subprocess
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.build import verify_builtin_calls


@pytest.mark.parametrize("problem", ["external-symbol", "plt-call", "no-call", None])
def test_wrapper_symbol_proof(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    problem: str | None,
) -> None:
    def run(args: list[str], **_kwargs: Any) -> subprocess.CompletedProcess[str]:
        if args[0] == "llvm-nm":
            kind = "U" if problem == "external-symbol" else "t"
            output = "\n".join(
                f"00001000 {kind} {name}" for name in ("memcpy", "memmove", "memset")
            )
        else:
            symbol = args[2].split("builtin_")[1]
            callee = f"{symbol}@plt" if problem == "plt-call" else symbol
            output = "ret" if problem == "no-call" else f"b 0x1000 <{callee}>"
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    monkeypatch.setattr(subprocess, "run", run)
    if problem is None:
        verify_builtin_calls(tmp_path / "bench-fastmem")
    else:
        with pytest.raises(ValueError, match="local"):
            verify_builtin_calls(tmp_path / "bench-fastmem")
