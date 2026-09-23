"""Build, execute, and analyze one reproducible experiment."""

import secrets
from typing import Any

import click

from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import parallel, progress
from ec2bench.runs import create_run, write_manifest
from fastmem_bench.analysis import BOOTSTRAP_SEED, analyze
from fastmem_bench.build import build_all, disassemble, provenance, resolve
from fastmem_bench.protocol import execute, orders
from fastmem_bench.report import write


@click.command()
@click.option("--rev", "revisions", multiple=True, default=("WORKTREE",))
@click.option("--target", "targets", multiple=True)
@click.option("--suite", type=click.Choice(["quick", "standard", "dist"]), default="standard")
@click.option("--rounds", type=click.IntRange(min=1), default=5, show_default=True)
@click.option(
    "--no-aa", is_flag=True, help="Disable the baseline duplicate and significance marks."
)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.option("--label", default="run", show_default=True)
@click.pass_obj
def run(
    config: Config,
    *,
    revisions: tuple[str, ...],
    targets: tuple[str, ...],
    suite: str,
    rounds: int,
    no_aa: bool,
    launch: bool,
    label: str,
) -> None:
    """Cross-build revisions and measure interleaved rounds across the fleet."""
    fleet = Fleet(config)
    names = config.select(targets)
    if launch:
        names = names or list(config.targets)
        ensure_up(fleet, names)
    if not names:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names:
        raise click.ClickException("No running targets. Use --up or select a target.")
    instances = {name: fleet.one(name) for name in names}
    path, manifest = create_run(
        config.root,
        label,
        names,
        {name: instance["InstanceId"] for name, instance in instances.items()},
    )
    seed = secrets.randbits(32)
    sources = resolve(config, revisions)
    variants = [source.variant for source in sources]
    schedule = orders([*variants, *([] if no_aa else ["aa"])], rounds, seed)
    manifest.update(
        {
            "seed": seed,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "rounds": rounds,
            "suite": suite,
            "aa": not no_aa,
            "schedule": schedule,
            "config": {"project": config.project, "targets": config.targets},
        }
    )
    write_manifest(path, manifest)
    builds = build_all(config, sources, names)
    manifest.update(provenance(sources, builds))
    write_manifest(path, manifest)
    outputs = fleet.outputs()

    def measure(name: str) -> dict[str, Any]:
        selected = []
        warnings = []
        for source in sources:
            outcome = builds[f"{source.variant}/{name}"]
            if outcome.error:
                raise RuntimeError(
                    f"Build failed: {source.revision}: {outcome.error}"
                ) from outcome.error
            if outcome.value is None:
                raise RuntimeError("Build returned no artifact")
            selected.append(outcome.value)
            warning = disassemble(outcome.value, path / name / "asm" / f"{source.variant}.asm")
            if warning:
                warnings.append(warning)
        box = box_for(fleet, instances[name], outputs)
        box.ready(config.project["image_version"])
        protocol = execute(
            config, box, selected, path, suite=suite, schedule=schedule, aa=not no_aa, seed=seed
        )
        progress("bootstrap analysis")
        result = analyze(path / name / "raw", variants, variants[0], aa=None if no_aa else "aa")
        result["protocol"] = protocol
        result["warnings"] = warnings + protocol.get("warnings", [])
        return result

    results = parallel(names, measure)
    summary = {
        "run_id": path.name,
        "variants": {source.variant: source.revision for source in sources},
        "bootstrap_seed": BOOTSTRAP_SEED,
        "targets": {
            name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
            for name, outcome in results.items()
        },
    }
    write(path, summary)
    manifest["status"] = {
        name: "failed" if outcome.error else "complete" for name, outcome in results.items()
    }
    write_manifest(path, manifest)
    click.echo(str(path))
    if any(outcome.error for outcome in results.values()):
        raise click.ClickException(
            "One or more targets failed. Successful target results remain available."
        )
