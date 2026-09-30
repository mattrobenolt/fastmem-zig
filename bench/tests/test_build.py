import subprocess
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.build import Build, Source, disassemble, source_hash


def test_source_hash(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / ".gitignore").write_text("cache/\n")
    (tmp_path / "source.zig").write_text("first")
    before = source_hash(tmp_path)
    (tmp_path / "cache").mkdir()
    (tmp_path / "cache/output").write_text("ignored")
    assert source_hash(tmp_path) == before
    (tmp_path / "source.zig").write_text("second")
    assert source_hash(tmp_path) != before
    subprocess.run(["git", "add", "source.zig"], cwd=tmp_path, check=True)
    staged = source_hash(tmp_path)
    (tmp_path / "source.zig").unlink()
    assert source_hash(tmp_path) != staged


def test_disassembly_missing_symbols_warns(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def run(*_args: Any, **_kwargs: Any) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], 0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", run)
    build = Build(Source("v0", "WORKTREE", tmp_path, "hash"), "intel", tmp_path, "key")
    destination = tmp_path / "asm/v0.asm"
    assert "missing disassembly symbols" in (disassemble(build, destination) or "")
    assert destination.with_suffix(".warning.txt").is_file()


def test_experiment_enters_build_args_and_cache_key(tmp_path: Path) -> None:
    from fastmem_bench.build import Source

    plain = Source("v0", "WORKTREE", tmp_path, "hash")
    assert plain.experiment == "auto"
    exp = Source("v0", "WORKTREE", tmp_path, "hash", "x86i_chunks")
    assert exp.experiment == "x86i_chunks"
    assert exp != plain


def test_undeclared_experiment_falls_back(tmp_path: Path) -> None:
    from fastmem_bench.build import declares_experiment

    (tmp_path / "build.zig").write_text("const X86Experiment = enum { auto, none, x86i_chunks };")
    assert declares_experiment(tmp_path, "auto")
    assert declares_experiment(tmp_path, "x86i_chunks")
    assert not declares_experiment(tmp_path, "x86i_mask16")
    assert not declares_experiment(tmp_path / "missing", "x86i_chunks")
