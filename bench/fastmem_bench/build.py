"""Source resolution and content-addressed cross builds."""

import hashlib
import json
import logging
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ec2bench.config import Config
from ec2bench.parallel import Outcome, parallel
from ec2bench.runs import git


@dataclass(frozen=True)
class Source:
    variant: str
    revision: str
    path: Path
    source_hash: str


@dataclass(frozen=True)
class Build:
    source: Source
    target: str
    prefix: Path
    cache_key: str


def source_hash(root: Path) -> str:
    digest = hashlib.sha256()
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        check=True,
        capture_output=True,
        timeout=60,
    ).stdout.split(b"\0")
    for name in sorted(set(files)):
        if not name:
            continue
        path = root / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link:" + os.fsencode(path.readlink()))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode() + b"\0" + path.read_bytes())
        else:
            digest.update(b"missing")
    return digest.hexdigest()


def resolve(config: Config, revisions: tuple[str, ...]) -> list[Source]:
    sources = []
    for index, revision in enumerate(revisions):
        if revision == "WORKTREE":
            path = config.root
            digest = source_hash(path)
        else:
            sha = git(config.root, "rev-parse", "--verify", f"{revision}^{{commit}}")
            path = config.root / ".bench-cache/src" / sha
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                git(config.root, "worktree", "add", "--detach", str(path), sha)
            if git(path, "status", "--porcelain"):
                raise ValueError(f"Cached source worktree is dirty: {path}")
            digest = sha
        sources.append(Source(f"v{index}", revision, path, digest))
    return sources


def build_all(
    config: Config, sources: list[Source], targets: list[str]
) -> dict[str, Outcome[Build]]:
    zig_version = subprocess.run(
        ["zig", "version"], check=True, capture_output=True, text=True, timeout=30
    ).stdout.strip()
    pairs = {
        f"{source.variant}/{target}": (source, target) for source in sources for target in targets
    }

    def build(name: str) -> Build:
        source, target = pairs[name]
        settings = config.targets[target]
        if settings["zig_cpu"] == "native":
            raise ValueError("Cross builds require an explicit CPU model")
        key_data = [
            source.source_hash,
            target,
            settings["zig_target"],
            settings["zig_cpu"],
            zig_version,
            source.revision,
            "ReleaseFast",
            True,
        ]
        key = hashlib.sha256(json.dumps(key_data).encode()).hexdigest()
        prefix = config.root / ".bench-cache/build" / key
        if not (prefix / "complete.json").exists():
            prefix.parent.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix="build-", dir=prefix.parent))
            try:
                args = [
                    "zig",
                    "build",
                    "install",
                    f"-Dtarget={settings['zig_target']}",
                    f"-Dcpu={settings['zig_cpu']}",
                    "-Doptimize=ReleaseFast",
                    "-Dlink-libc=true",
                    f"-Drev={source.revision}",
                    "--prefix",
                    str(temporary),
                ]
                completed = subprocess.run(
                    args, cwd=source.path, capture_output=True, text=True, timeout=1200, check=False
                )
                (temporary / "build.log").write_text(completed.stdout + completed.stderr)
                if completed.returncode:
                    log = prefix.parent / f"{key}.failed.log"
                    (temporary / "build.log").replace(log)
                    raise RuntimeError(
                        f"Cross build failed. Read {log}: {completed.stderr[-2000:]}"
                    )
                for binary in ("bench-fastmem", "libc-probe"):
                    if not (temporary / "bin" / binary).is_file():
                        raise FileNotFoundError(f"Build did not install {binary}")
                (temporary / "complete.json").write_text(
                    json.dumps({"key": key_data, "command": args})
                )
                try:
                    temporary.rename(prefix)
                except FileExistsError:
                    if not (prefix / "complete.json").exists():
                        raise
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        return Build(source, target, prefix, key)

    return parallel(pairs, build, workers=os.cpu_count() or 1)


def disassemble(build: Build, destination: Path) -> str | None:
    binary = build.prefix / "bin/bench-fastmem"
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = {"fastmem_copy", "fastmem_move", "builtin_memcpy", "builtin_memmove"}
    try:
        symbols = subprocess.run(
            ["llvm-objdump", "--syms", str(binary)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        ).stdout
        names = sorted(
            {
                line.split()[-1]
                for line in symbols.splitlines()
                if line.split() and line.split()[-1].startswith(("fastmem_", "builtin_"))
            }
        )
        missing = expected - set(names)
        warning = (
            f"{binary}: missing disassembly symbols: {', '.join(sorted(missing))}"
            if missing
            else None
        )
        if names:
            result = subprocess.run(
                ["llvm-objdump", "-d", "--disassemble-symbols=" + ",".join(names), str(binary)],
                check=True,
                capture_output=True,
                text=True,
                timeout=120,
            )
            destination.write_text(result.stdout)
    except (OSError, subprocess.SubprocessError) as error:
        warning = f"{binary}: disassembly failed: {error}"
    if warning:
        logging.getLogger(__name__).warning("%s", warning)
        destination.with_suffix(".warning.txt").write_text(warning + "\n")
    return warning


def provenance(sources: list[Source], results: dict[str, Outcome[Build]]) -> dict[str, Any]:
    return {
        "sources": [
            {
                "variant": source.variant,
                "revision": source.revision,
                "hash": source.source_hash,
                "path": str(source.path),
            }
            for source in sources
        ],
        "builds": {
            key: {"cache_key": result.value.cache_key, "prefix": str(result.value.prefix)}
            if result.value
            else {"error": str(result.error)}
            for key, result in results.items()
        },
    }
