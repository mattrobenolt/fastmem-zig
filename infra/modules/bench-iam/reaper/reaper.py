"""Out-of-guest reaper for a tag-scoped EC2 benchmark fleet.

EventBridge invokes handler() every 5 minutes. The handler reads the live
instances, the available volumes, and the available network interfaces of
the region, keeps the ones of the project, and acts on them:

- It terminates an instance that is stopped or stopping, that has no
  ExpiresAt tag in RFC 3339 UTC, that is past ExpiresAt, or that is past
  LaunchTime plus the maximum lifetime.
- It deletes a volume that is available and older than 10 minutes.
- It marks an available network interface with an OrphanSeenAt tag, and
  deletes it 10 minutes after the mark. EC2 does not report when it created
  a network interface, so the mark stands in for the creation time.

The decision functions are pure: they take `now` as an argument and make no
AWS call. test_reaper.py covers them and run(). boto3 comes from the Lambda
runtime. Only handler() imports it, so the tests need no AWS SDK.
"""

import json
import logging
import os
import re
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

logger = logging.getLogger("reaper")

EXPIRES_AT = "ExpiresAt"
ORPHAN_SEEN_AT = "OrphanSeenAt"
ORPHAN_MIN_AGE = timedelta(minutes=10)

# Instance states that the reaper reads. It ignores shutting-down and
# terminated instances.
LIVE_STATES = ("pending", "running", "stopping", "stopped")

# The format that the harness writes and the TTL guard on the box accepts:
# 2026-09-24T04:00:00Z. Whole seconds, Z suffix, nothing else.
_RFC3339_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def parse_utc(value: str | None) -> datetime | None:
    """Return the time in an RFC 3339 UTC string, or None for any other value."""
    if value is None or not _RFC3339_UTC.fullmatch(value):
        return None
    try:
        return datetime.strptime(value, _FORMAT).replace(tzinfo=UTC)
    except ValueError:
        # The shape matches, but the date does not exist (2026-02-30).
        return None


def format_utc(value: datetime) -> str:
    return value.astimezone(UTC).strftime(_FORMAT)


def tags_of(resource: Mapping[str, Any]) -> dict[str, str]:
    """Return the tags of an instance or volume (Tags) or interface (TagSet)."""
    pairs = resource.get("Tags") or resource.get("TagSet") or []
    return {pair["Key"]: pair["Value"] for pair in pairs}


def in_project(tags: Mapping[str, str], project: str) -> bool:
    """Return True if a Project tag key, in any case, has the project value.

    IAM compares the tag key of aws:ResourceTag/Project without case, so a
    resource with PROJECT=<project> is inside the IAM boundary. The reaper
    must see it too.
    """
    return any(key.lower() == "project" and value == project for key, value in tags.items())


def instance_reason(
    instance: Mapping[str, Any], now: datetime, max_lifetime: timedelta
) -> str | None:
    """Return why the reaper must terminate the instance, or None to keep it."""
    state = instance["State"]["Name"]
    if state in ("shutting-down", "terminated"):
        return None
    if state in ("stopping", "stopped"):
        return f"state is {state}"
    # The exact key: the TTL guard reads ExpiresAt from IMDS with this case.
    raw = tags_of(instance).get(EXPIRES_AT)
    if raw is None:
        return "no ExpiresAt tag"
    expires = parse_utc(raw)
    if expires is None:
        return f"ExpiresAt {raw!r} is not an RFC 3339 UTC time"
    if now > expires:
        return f"expired at {raw}"
    launched = instance["LaunchTime"]
    if now > launched + max_lifetime:
        return f"launched at {format_utc(launched)}, past the maximum lifetime of {max_lifetime}"
    return None


def volume_reason(volume: Mapping[str, Any], now: datetime) -> str | None:
    """Return why the reaper must delete the volume, or None to keep it."""
    if volume["State"] != "available":
        return None
    created = volume["CreateTime"]
    if now - created <= ORPHAN_MIN_AGE:
        return None
    return f"available, created at {format_utc(created)}"


def interface_action(interface: Mapping[str, Any], now: datetime) -> str | None:
    """Return "mark", "delete", or None for a network interface.

    A mark in the future is not valid: the reaper writes the mark, and it
    writes the current time.
    """
    if interface["Status"] != "available":
        return None
    seen = parse_utc(tags_of(interface).get(ORPHAN_SEEN_AT))
    if seen is None or seen > now:
        return "mark"
    if now - seen > ORPHAN_MIN_AGE:
        return "delete"
    return None


@dataclass
class Plan:
    terminate: dict[str, str] = field(default_factory=dict)
    delete_volumes: dict[str, str] = field(default_factory=dict)
    mark_interfaces: list[str] = field(default_factory=list)
    delete_interfaces: list[str] = field(default_factory=list)


def plan(
    project: str,
    instances: Iterable[Mapping[str, Any]],
    volumes: Iterable[Mapping[str, Any]],
    interfaces: Iterable[Mapping[str, Any]],
    now: datetime,
    max_lifetime: timedelta,
) -> Plan:
    """Select the actions for the project resources. Ignore all other resources."""
    result = Plan()
    for instance in instances:
        if in_project(tags_of(instance), project):
            reason = instance_reason(instance, now, max_lifetime)
            if reason:
                result.terminate[instance["InstanceId"]] = reason
    for volume in volumes:
        if in_project(tags_of(volume), project):
            reason = volume_reason(volume, now)
            if reason:
                result.delete_volumes[volume["VolumeId"]] = reason
    for interface in interfaces:
        if in_project(tags_of(interface), project):
            action = interface_action(interface, now)
            if action == "mark":
                result.mark_interfaces.append(interface["NetworkInterfaceId"])
            elif action == "delete":
                result.delete_interfaces.append(interface["NetworkInterfaceId"])
    return result


@dataclass(frozen=True)
class Config:
    project: str
    region: str
    max_lifetime: timedelta
    dry_run: bool

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Config":
        seconds = int(env["MAX_LIFETIME_SECONDS"])
        if seconds <= 0:
            raise ValueError("MAX_LIFETIME_SECONDS must be positive")
        dry_run = env.get("DRY_RUN", "false").lower()
        if dry_run not in ("true", "false"):
            raise ValueError("DRY_RUN must be true or false")
        project = env["PROJECT"]
        if not project:
            raise ValueError("PROJECT must not be empty")
        return cls(
            project=project,
            region=env["REGION"],
            max_lifetime=timedelta(seconds=seconds),
            dry_run=dry_run == "true",
        )


def _error_code(error: Exception) -> str | None:
    """Return the AWS error code of a botocore ClientError, else None."""
    response = getattr(error, "response", None)
    if isinstance(response, dict):
        return response.get("Error", {}).get("Code")
    return None


def _call(fn: Callable[..., Any], dry_run: bool, **kwargs: Any) -> str | None:
    """Make one mutating EC2 call. Return None on success, else the error code.

    With dry_run, EC2 checks the permissions and changes nothing: it answers
    DryRunOperation if the call would succeed. A NotFound error means that
    the resource is already gone, which is the goal. Other exceptions (not
    from the AWS API) propagate.
    """
    try:
        fn(DryRun=dry_run, **kwargs)
    except Exception as error:
        code = _error_code(error)
        if code is None:
            raise
        if code == "DryRunOperation" and dry_run:
            return None
        if code.endswith(".NotFound"):
            return None
        return code
    return None


def _terminate(ec2: Any, instance_id: str, dry_run: bool) -> str | None:
    code = _call(ec2.terminate_instances, dry_run, InstanceIds=[instance_id])
    if code == "OperationNotPermitted":
        # Termination protection. The bench user can set it with
        # DisableApiTermination in a launch template or a request.
        code = _call(
            ec2.modify_instance_attribute,
            dry_run,
            InstanceId=instance_id,
            DisableApiTermination={"Value": False},
        )
        if code is None:
            code = _call(ec2.terminate_instances, dry_run, InstanceIds=[instance_id])
    return code


def _pages(ec2: Any, operation: str, key: str, filters: list[dict[str, Any]]) -> list[Any]:
    items: list[Any] = []
    for page in ec2.get_paginator(operation).paginate(Filters=filters):
        items.extend(page[key])
    return items


def _log(event: dict[str, Any]) -> None:
    logger.info(json.dumps(event, sort_keys=True))


def run(ec2: Any, config: Config, now: datetime) -> dict[str, Any]:
    """Read the region, plan, and act. Raise if an action failed."""
    reservations = _pages(
        ec2,
        "describe_instances",
        "Reservations",
        [{"Name": "instance-state-name", "Values": list(LIVE_STATES)}],
    )
    instances = [instance for r in reservations for instance in r["Instances"]]
    volumes = _pages(
        ec2, "describe_volumes", "Volumes", [{"Name": "status", "Values": ["available"]}]
    )
    interfaces = _pages(
        ec2,
        "describe_network_interfaces",
        "NetworkInterfaces",
        [{"Name": "status", "Values": ["available"]}],
    )

    actions = plan(config.project, instances, volumes, interfaces, now, config.max_lifetime)
    dry_run = config.dry_run
    errors: list[dict[str, str]] = []

    def record(action: str, resource_id: str, code: str | None, **extra: str) -> None:
        event = {"action": action, "id": resource_id, "dry_run": dry_run, **extra}
        event["result"] = code or "ok"
        _log(event)
        if code:
            errors.append({"action": action, "id": resource_id, "code": code})

    for instance_id, reason in actions.terminate.items():
        record("terminate", instance_id, _terminate(ec2, instance_id, dry_run), reason=reason)
    for volume_id, reason in actions.delete_volumes.items():
        code = _call(ec2.delete_volume, dry_run, VolumeId=volume_id)
        record("delete-volume", volume_id, code, reason=reason)
    for interface_id in actions.mark_interfaces:
        code = _call(
            ec2.create_tags,
            dry_run,
            Resources=[interface_id],
            Tags=[{"Key": ORPHAN_SEEN_AT, "Value": format_utc(now)}],
        )
        record("mark-interface", interface_id, code)
    for interface_id in actions.delete_interfaces:
        code = _call(ec2.delete_network_interface, dry_run, NetworkInterfaceId=interface_id)
        record("delete-interface", interface_id, code)

    summary = {
        "project": config.project,
        "dry_run": dry_run,
        "now": format_utc(now),
        "instances_read": len(instances),
        "terminate": actions.terminate,
        "delete_volumes": actions.delete_volumes,
        "mark_interfaces": actions.mark_interfaces,
        "delete_interfaces": actions.delete_interfaces,
        "errors": errors,
    }
    _log({"summary": summary})
    if errors:
        # A failed invocation shows in the Errors metric of the function.
        raise RuntimeError(f"{len(errors)} reaper action(s) failed: {errors}")
    return summary


def handler(event: Any, context: Any) -> dict[str, Any]:
    import boto3  # From the Lambda runtime.

    logging.getLogger().setLevel(logging.INFO)
    config = Config.from_env(os.environ)
    ec2 = boto3.client("ec2", region_name=config.region)
    return run(ec2, config, datetime.now(UTC))
