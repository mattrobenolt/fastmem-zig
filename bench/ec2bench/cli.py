"""Generic commands and the project adapter hook."""

import importlib
import json
from collections import Counter
from datetime import UTC, datetime
from typing import Any

import click
from rich.console import Console
from rich.table import Table

from ec2bench.box import Box
from ec2bench.config import Config
from ec2bench.facts import collect
from ec2bench.fleet import Fleet, expiry, tags
from ec2bench.parallel import parallel, progress

console = Console()


def box_for(fleet: Fleet, instance: dict[str, Any], outputs: dict[str, Any]) -> Box:
    host = instance.get("PublicIpAddress")
    if not host:
        raise ValueError(f"No public IP for {instance['InstanceId']}")
    return Box(
        instance["InstanceId"],
        host,
        fleet.key_path(outputs),
        fleet.config.root / ".bench-cache/ssh",
    )


def ensure_up(
    fleet: Fleet, names: list[str], ttl: str | None = None, size: str | None = None
) -> None:
    outputs = fleet.outputs()

    def launch(name: str) -> str:
        instance = fleet.launch(name, ttl or fleet.config.fleet["default_ttl"], size, outputs)
        progress("wait for EC2")
        instance = fleet.wait_running(instance["InstanceId"])
        progress("wait for SSH and image")
        box_for(fleet, instance, outputs).ready(fleet.config.project["image_version"])
        return instance["InstanceId"]

    results = parallel(names, launch)
    if any(result.error for result in results.values()):
        raise click.ClickException("Some targets failed to start. Their TTL tags remain active.")


@click.group()
@click.pass_context
def cli(ctx: click.Context) -> None:
    """Manage a tagged benchmark fleet and run project adapters."""
    ctx.obj = Config.load()


@cli.command()
@click.argument("targets", nargs=-1, required=True)
@click.option("--ttl", default=None, help="Lifetime: positive integer plus m, h, or d.")
@click.option("--size", default=None, help="Override the instance size, for example xlarge.")
@click.pass_obj
def up(config: Config, targets: tuple[str, ...], ttl: str | None, size: str | None) -> None:
    """Launch missing targets and wait for the image marker."""
    ensure_up(Fleet(config), config.select(targets), ttl, size)


@cli.command(name="ls")
@click.pass_obj
def list_instances(config: Config) -> None:
    """Show all instances with this project's tag."""
    table = Table("Target", "Instance", "Type", "State", "IP", "TTL")
    instances = Fleet(config).instances()
    counts = Counter(tags(instance).get("Target") for instance in instances)
    for instance in instances:
        values = tags(instance)
        target = values.get("Target", "?")
        if counts[target] > 1:
            target += " [DUPLICATE]"
        expires = expiry(values.get("ExpiresAt"))
        remaining = str(expires - datetime.now(UTC)).split(".")[0] if expires else "missing/invalid"
        table.add_row(
            target,
            instance["InstanceId"],
            instance["InstanceType"],
            instance["State"]["Name"],
            instance.get("PublicIpAddress", "-"),
            remaining,
        )
    console.print(table)


@cli.command()
@click.argument("targets", nargs=-1)
@click.option("--all", "all_targets", is_flag=True)
@click.pass_obj
def down(config: Config, targets: tuple[str, ...], all_targets: bool) -> None:
    """Terminate selected targets or the whole project fleet."""
    if bool(targets) == all_targets:
        raise click.UsageError("Specify targets or --all, but not both")
    fleet = Fleet(config)
    instances = fleet.instances() if all_targets else fleet.selected(config.select(targets))
    fleet.terminate([instance["InstanceId"] for instance in instances])


@cli.command()
@click.argument("targets", nargs=-1, required=True)
@click.option("--ttl", required=True)
@click.pass_obj
def extend(config: Config, targets: tuple[str, ...], ttl: str) -> None:
    """Set expiration to the current time plus the TTL."""
    Fleet(config).extend(config.select(targets), ttl)


@cli.command()
@click.pass_obj
def reap(config: Config) -> None:
    """Terminate expired instances and instances without valid expiration tags."""
    console.print(Fleet(config).reap())


@cli.command(context_settings={"ignore_unknown_options": True})
@click.argument("target")
@click.argument("command", nargs=-1, type=click.UNPROCESSED)
@click.pass_obj
def ssh(config: Config, target: str, command: tuple[str, ...]) -> None:
    """Open a shell or execute a command on one target."""
    fleet = Fleet(config)
    box_for(fleet, fleet.one(target), fleet.outputs()).shell(command)


@cli.command()
@click.argument("targets", nargs=-1, required=True)
@click.pass_obj
def facts(config: Config, targets: tuple[str, ...]) -> None:
    """Collect and cache host facts by instance ID."""
    fleet = Fleet(config)
    outputs = fleet.outputs()
    results = parallel(
        config.select(targets),
        lambda name: collect(box_for(fleet, fleet.one(name), outputs), config.root),
    )
    for name, result in results.items():
        if result.error is None:
            console.print_json(json.dumps({name: result.value}))
    if any(result.error for result in results.values()):
        raise click.ClickException("Host facts failed for one or more targets")


def main() -> None:
    try:
        config = Config.load()
        if adapter := config.project.get("adapter"):
            importlib.import_module(adapter).register(cli)
        cli()
    except (ValueError, FileNotFoundError) as error:
        click.ClickException(str(error)).show()
        raise SystemExit(1) from error
