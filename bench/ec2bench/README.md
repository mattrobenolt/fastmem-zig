# ec2bench

`ec2bench` manages a tag-scoped EC2 fleet. A project adapter supplies benchmark commands.
The package contains no benchmark-specific build or analysis code.

## Adoption procedure

1. Copy `ec2bench/` into your Python project.
2. Copy the infrastructure pattern into `infra/`.
3. Add `boto3`, `click`, and `rich` to your dependencies.
4. Register `bench = "ec2bench.cli:main"` as a project script.
5. Create `bench.toml` at the repository root.
6. Set the project name and AWS profile to your project's values.
7. Add each target's instance type and architecture.
8. Apply the infrastructure with OpenTofu.
9. Run `bench up <target>`.

## Configuration

```toml
[project]
name = "example-bench"
region = "us-west-2"
profile = "example-bench"
adapter = "example_bench"
remote_dir = "/root/bench"
image_version = "1"

[fleet]
default_ttl = "4h"
default_owner = "agent"

[targets.intel]
instance_type = "c7i.xlarge"
arch = "x86_64"
```

The architecture is `x86_64` or `arm64`. Unknown configuration keys belong to the adapter.
The `AWS_PROFILE` environment variable overrides the configured profile.

The base stack exports `launch_template_ids`, `key_file`, and `security_group_id`.
`launch_template_ids` maps architecture names to template IDs.
A relative `key_file` path starts at `infra/base/`.
The image exposes its version in `/etc/bench-image`.

## Adapter interface

The configured adapter exports `register(group)`. This function attaches Click commands to the group.
Each command receives `Config` through `click.pass_obj`.

```python
import click
from ec2bench.config import Config


def register(group: click.Group) -> None:
    @group.command()
    @click.pass_obj
    def run(config: Config) -> None:
        click.echo(config.root)
```

`Fleet` manages instances through project tags. `Box` provides SSH commands and file transfers.
`parallel` returns independent results and errors for each task.
`facts.collect` caches host facts under `bench-results/.facts/`.
`isolation.isolate` restores cpuset properties when its context exits.
`runs.create_run` records source provenance and instance IDs.

## Safety

Every new instance receives an expiration tag. The image must enforce this tag with its shutdown timer.
The launch template must set shutdown behavior to `terminate`.
The `reap` command treats absent or malformed expiration tags as expired.

Concurrent `up` commands for the same target are unsupported. EC2 tags do not provide an atomic claim.
After a launch, the harness selects the earliest instance and terminates duplicates that it discovers.
The lowest instance ID breaks ties. Eventual consistency can delay duplicate discovery.
The `ls` command flags duplicate targets. Separate processes can operate on different targets.
