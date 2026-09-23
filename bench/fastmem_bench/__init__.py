"""Adapter registration."""

import click


def register(group: click.Group) -> None:
    from fastmem_bench.runner import run

    group.add_command(run)
