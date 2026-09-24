"""Cross-build and execute the guard suite without benchmark CPU isolation."""

import hashlib
import json
import shlex
import subprocess
from pathlib import Path
from typing import Any

import click
from rich.console import Console
from rich.table import Table

from ec2bench.box import Box
from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import parallel
from ec2bench.runs import create_run, write_manifest
from fastmem_bench.build import source_hash


def cpus(settings: dict[str, Any]) -> dict[str, str]:
    cpu = settings["zig_cpu"]
    if cpu == "native":
        raise ValueError("Correctness cross builds require an explicit CPU model")
    baseline = "x86_64_v3" if settings["zig_target"].startswith("x86_64-") else "generic"
    return {"target": cpu, "baseline": baseline}


def build_binary(config: Config, target: str, cpu: str, path: Path) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    command = [
        "zig",
        "build",
        "test-bin",
        f"-Dtarget={config.targets[target]['zig_target']}",
        f"-Dcpu={cpu}",
        "-Doptimize=ReleaseFast",
        "--prefix",
        str(path.resolve()),
    ]
    result = subprocess.run(
        command,
        cwd=config.root,
        capture_output=True,
        text=True,
        timeout=1200,
        check=False,
    )
    (path / "build.log").write_text(result.stdout + result.stderr)
    (path / "command.json").write_text(json.dumps(command) + "\n")
    if result.returncode:
        raise RuntimeError(f"Cross build failed: {path / 'build.log'}")
    binary = path / "bin/fastmem-tests"
    return {
        "command": command,
        "cpu": cpu,
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }


def parse_summary(text: str, cpu: str) -> dict[str, Any]:
    lines = text.splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one correctness JSON summary")
    result = json.loads(lines[0])
    if not isinstance(result, dict) or result.get("schema") != 1:
        raise ValueError("Invalid correctness summary schema")
    if result.get("status") not in {"pass", "fail"}:
        raise ValueError("Invalid correctness status")
    if result.get("cpu") != cpu or result.get("optimize") != "ReleaseFast":
        raise ValueError("Correctness binary CPU or optimization mismatch")
    if type(result.get("cases")) is not int or result["cases"] < 0:
        raise ValueError("Invalid correctness case count")
    if result["status"] == "pass" and result["cases"] == 0:
        raise ValueError("Correctness binary ran no cases")
    if type(result.get("set_available")) is not bool:
        raise ValueError("Missing set availability")
    impl = result.get("impl")
    if not isinstance(impl, dict) or any(
        not isinstance(impl.get(op), str) or not impl[op] for op in ("copy", "move", "set")
    ):
        raise ValueError("Missing correctness kernel identifiers")
    return result


def execute_binary(box: Box, binary: Path, remote: str, path: Path, cpu: str) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    box.upload(binary, remote)
    directory = shlex.quote(remote)
    # Save both channels and the exit status, including faults and missing interpreters.
    command = (
        f"cd {directory} && "
        "(ulimit -c 0; ./fastmem-tests >summary.json 2>stderr.txt; "
        "status=$?; printf '%s\\n' \"$status\" >exit-status.txt)"
    )
    try:
        box.run(command, timeout=600)
    finally:
        box.download(remote, path)
    status = int((path / "exit-status.txt").read_text().strip())
    summary = parse_summary((path / "summary.json").read_text(), cpu)
    summary["exit_status"] = status
    if status != 0 or summary["status"] != "pass":
        summary["error"] = f"Suite failed: exit={status}, detail={summary.get('detail', '')}"
    return summary


def run_variant(
    config: Config,
    box: Box,
    target: str,
    variant: str,
    cpu: str,
    *,
    path: Path,
) -> dict[str, Any]:
    result: dict[str, Any] = {"cpu": cpu}
    local = path / target / variant
    try:
        result["build"] = build_binary(config, target, cpu, local / "build")
        remote = f"{config.project['remote_dir']}/{path.name}/{target}/{variant}"
        result.update(
            execute_binary(
                box,
                local / "build/bin/fastmem-tests",
                remote,
                local / "raw",
                cpu,
            )
        )
    except Exception as error:  # noqa: BLE001 — preserve the other variant's evidence
        result["error"] = str(error)
    return result


@click.command(name="test")
@click.option("--target", "targets", multiple=True)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.pass_obj
def test_fleet(config: Config, targets: tuple[str, ...], launch: bool) -> None:
    """Run target-CPU and baseline-CPU correctness binaries on each box."""
    fleet = Fleet(config)
    names = config.select(targets)
    startup = {}
    if launch:
        startup = ensure_up(fleet, names or list(config.targets))
        names = [name for name, outcome in startup.items() if outcome.error is None]
    elif not names:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names and not startup:
        raise click.ClickException("No running targets. Use --up or select a target.")
    path, manifest = create_run(
        config.root,
        "test",
        list(startup) if launch else names,
        {},
        results_dir=config.results_dir,
    )
    manifest.update(
        {
            "kind": "correctness",
            "source_hash": source_hash(config.root),
            "config": {"project": config.project, "targets": config.targets},
            "zig_version": subprocess.run(
                ["zig", "version"],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            ).stdout.strip(),
        }
    )
    write_manifest(path, manifest)
    outputs = fleet.outputs() if names else {}

    def check_target(name: str) -> dict[str, Any]:
        instance = fleet.one(name)
        box = box_for(fleet, instance, outputs)
        box.ready(config.project["image_version"])
        variants = {
            variant: run_variant(config, box, name, variant, cpu, path=path)
            for variant, cpu in cpus(config.targets[name]).items()
        }
        return {"instance": instance["InstanceId"], "variants": variants}

    results = parallel(names, check_target)
    summary: dict[str, Any] = {
        name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
        for name, outcome in results.items()
    }
    summary.update(
        {
            name: {"error": str(outcome.error)}
            for name, outcome in startup.items()
            if outcome.error is not None
        }
    )
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    table = Table("Target", "Target CPU", "Baseline CPU", "Set")
    for name, result in summary.items():
        variants = result.get("variants", {})
        statuses = [
            "PASS"
            if variants.get(v, {}).get("status") == "pass" and "error" not in variants[v]
            else "FAIL"
            for v in ("target", "baseline")
        ]
        table.add_row(
            name,
            *statuses,
            "tested"
            if all(variants.get(v, {}).get("set_available") for v in ("target", "baseline"))
            else "unavailable",
        )
        manifest.setdefault("instances", {})[name] = result.get("instance")
        manifest.setdefault("status", {})[name] = "failed" if "FAIL" in statuses else "complete"
    Console().print(table)
    write_manifest(path, manifest)
    click.echo(str(path))
    if "failed" in manifest["status"].values():
        raise click.ClickException(
            "Correctness failed. Read summary.json and per-variant raw files."
        )
