"""Unit tests for reaper.py. They need no AWS SDK and no credentials.

Run from the repository root:

    nix develop -c python3 -m unittest discover -s infra/modules/bench-iam/reaper -v
    nix develop -c uv run --with pytest pytest infra/modules/bench-iam/reaper
"""

import unittest
from datetime import UTC, datetime, timedelta

import reaper

PROJECT = "fastmem-bench"
NOW = datetime(2026, 9, 24, 12, 0, 0, tzinfo=UTC)
DAY = timedelta(hours=24)


def tags(**pairs: str) -> list[dict[str, str]]:
    return [{"Key": key, "Value": value} for key, value in pairs.items()]


def instance(
    instance_id: str = "i-1",
    state: str = "running",
    launched: datetime = NOW - timedelta(hours=1),
    **tag_pairs: str,
) -> dict:
    tag_pairs.setdefault("Project", PROJECT)
    return {
        "InstanceId": instance_id,
        "State": {"Name": state},
        "LaunchTime": launched,
        "Tags": tags(**tag_pairs),
    }


def volume(
    volume_id: str = "vol-1",
    state: str = "available",
    created: datetime = NOW - timedelta(hours=1),
    **tag_pairs: str,
) -> dict:
    tag_pairs.setdefault("Project", PROJECT)
    return {"VolumeId": volume_id, "State": state, "CreateTime": created, "Tags": tags(**tag_pairs)}


def interface(interface_id: str = "eni-1", status: str = "available", **tag_pairs: str) -> dict:
    tag_pairs.setdefault("Project", PROJECT)
    return {"NetworkInterfaceId": interface_id, "Status": status, "TagSet": tags(**tag_pairs)}


class ParseUtcTest(unittest.TestCase):
    def test_valid(self) -> None:
        self.assertEqual(reaper.parse_utc("2026-09-24T04:00:00Z"), datetime(2026, 9, 24, 4, tzinfo=UTC))
        self.assertEqual(
            reaper.parse_utc("9999-12-31T23:59:59Z"), datetime(9999, 12, 31, 23, 59, 59, tzinfo=UTC)
        )

    def test_invalid(self) -> None:
        for value in [
            None,
            "",
            "9999",
            "tomorrow",
            "2026-09-24",
            "2026-09-24T04:00:00",
            "2026-09-24T04:00:00z",
            "2026-09-24T04:00:00+00:00",
            "2026-09-24T04:00:00.000Z",
            "2026-09-24 04:00:00Z",
            "2026-09-24T04:00:00Z\n",
            " 2026-09-24T04:00:00Z",
            "2026-02-30T04:00:00Z",
            "2026-09-24T25:00:00Z",
            "２０２６-09-24T04:00:00Z",
        ]:
            with self.subTest(value=value):
                self.assertIsNone(reaper.parse_utc(value))


class InProjectTest(unittest.TestCase):
    def test_case_of_key_does_not_matter(self) -> None:
        for key in ["Project", "project", "PROJECT", "pRoJeCt"]:
            with self.subTest(key=key):
                self.assertTrue(reaper.in_project({key: PROJECT}, PROJECT))

    def test_value_must_match_exactly(self) -> None:
        self.assertFalse(reaper.in_project({"Project": "FASTMEM-BENCH"}, PROJECT))
        self.assertFalse(reaper.in_project({"Project": "other"}, PROJECT))
        self.assertFalse(reaper.in_project({"Name": PROJECT}, PROJECT))
        self.assertFalse(reaper.in_project({}, PROJECT))


class InstanceReasonTest(unittest.TestCase):
    def reason(self, item: dict) -> str | None:
        return reaper.instance_reason(item, NOW, DAY)

    def test_keeps_a_healthy_box(self) -> None:
        self.assertIsNone(self.reason(instance(ExpiresAt="2026-09-24T16:00:00Z")))
        self.assertIsNone(self.reason(instance(state="pending", ExpiresAt="2026-09-24T16:00:00Z")))

    def test_expires_at_equal_to_now_is_not_yet_expired(self) -> None:
        self.assertIsNone(self.reason(instance(ExpiresAt="2026-09-24T12:00:00Z")))

    def test_ignores_instances_that_are_already_going(self) -> None:
        for state in ["shutting-down", "terminated"]:
            with self.subTest(state=state):
                self.assertIsNone(self.reason(instance(state=state)))

    def test_terminates_stopped_and_stopping(self) -> None:
        for state in ["stopped", "stopping"]:
            with self.subTest(state=state):
                self.assertEqual(
                    self.reason(instance(state=state, ExpiresAt="2026-09-24T16:00:00Z")),
                    f"state is {state}",
                )

    def test_terminates_without_expires_at(self) -> None:
        self.assertEqual(self.reason(instance()), "no ExpiresAt tag")

    def test_expires_at_key_is_exact(self) -> None:
        # The TTL guard reads ExpiresAt with this case, so another case is no tag.
        self.assertEqual(self.reason(instance(EXPIRESAT="2026-09-24T16:00:00Z")), "no ExpiresAt tag")

    def test_terminates_with_malformed_expires_at(self) -> None:
        for value in ["9999", "", "2026-09-24T16:00:00+00:00", "never"]:
            with self.subTest(value=value):
                self.assertIn("is not an RFC 3339 UTC time", self.reason(instance(ExpiresAt=value)))

    def test_terminates_after_expires_at(self) -> None:
        self.assertEqual(
            self.reason(instance(ExpiresAt="2026-09-24T11:59:59Z")), "expired at 2026-09-24T11:59:59Z"
        )

    def test_max_lifetime_overrides_a_far_expires_at(self) -> None:
        old = instance(launched=NOW - DAY - timedelta(seconds=1), ExpiresAt="9999-12-31T23:59:59Z")
        self.assertIn("past the maximum lifetime", self.reason(old))
        young = instance(launched=NOW - DAY, ExpiresAt="9999-12-31T23:59:59Z")
        self.assertIsNone(self.reason(young))


class VolumeReasonTest(unittest.TestCase):
    def test_deletes_old_available_volume(self) -> None:
        self.assertIsNotNone(reaper.volume_reason(volume(), NOW))

    def test_keeps_young_or_attached_volume(self) -> None:
        self.assertIsNone(reaper.volume_reason(volume(created=NOW - timedelta(minutes=10)), NOW))
        self.assertIsNone(reaper.volume_reason(volume(created=NOW - timedelta(minutes=2)), NOW))
        for state in ["creating", "in-use", "deleting"]:
            with self.subTest(state=state):
                self.assertIsNone(reaper.volume_reason(volume(state=state), NOW))


class InterfaceActionTest(unittest.TestCase):
    def test_marks_an_unmarked_available_interface(self) -> None:
        self.assertEqual(reaper.interface_action(interface(), NOW), "mark")

    def test_marks_again_when_the_mark_is_not_valid(self) -> None:
        self.assertEqual(reaper.interface_action(interface(OrphanSeenAt="junk"), NOW), "mark")
        self.assertEqual(
            reaper.interface_action(interface(OrphanSeenAt="2026-09-25T00:00:00Z"), NOW), "mark"
        )

    def test_waits_ten_minutes_after_the_mark(self) -> None:
        self.assertIsNone(reaper.interface_action(interface(OrphanSeenAt="2026-09-24T11:50:00Z"), NOW))
        self.assertEqual(
            reaper.interface_action(interface(OrphanSeenAt="2026-09-24T11:49:59Z"), NOW), "delete"
        )

    def test_ignores_attached_interfaces(self) -> None:
        for status in ["in-use", "attaching", "detaching", "associated"]:
            with self.subTest(status=status):
                self.assertIsNone(
                    reaper.interface_action(
                        interface(status=status, OrphanSeenAt="2026-09-24T00:00:00Z"), NOW
                    )
                )


class PlanTest(unittest.TestCase):
    def test_acts_only_on_project_resources(self) -> None:
        result = reaper.plan(
            PROJECT,
            instances=[
                instance("i-mine"),
                instance("i-case", Project="x", PROJECT=PROJECT),
                instance("i-other", Project="other"),
                instance("i-ok", ExpiresAt="2026-09-24T16:00:00Z"),
            ],
            volumes=[volume("vol-mine"), volume("vol-other", Project="other")],
            interfaces=[
                interface("eni-new"),
                interface("eni-old", OrphanSeenAt="2026-09-24T11:00:00Z"),
                interface("eni-other", Project="other"),
            ],
            now=NOW,
            max_lifetime=DAY,
        )
        self.assertEqual(set(result.terminate), {"i-mine", "i-case"})
        self.assertEqual(set(result.delete_volumes), {"vol-mine"})
        self.assertEqual(result.mark_interfaces, ["eni-new"])
        self.assertEqual(result.delete_interfaces, ["eni-old"])


class ConfigTest(unittest.TestCase):
    ENV = {"PROJECT": PROJECT, "REGION": "us-west-2", "MAX_LIFETIME_SECONDS": "86400"}

    def test_defaults(self) -> None:
        config = reaper.Config.from_env(self.ENV)
        self.assertEqual(config.max_lifetime, DAY)
        self.assertFalse(config.dry_run)

    def test_dry_run(self) -> None:
        self.assertTrue(reaper.Config.from_env({**self.ENV, "DRY_RUN": "true"}).dry_run)
        self.assertFalse(reaper.Config.from_env({**self.ENV, "DRY_RUN": "false"}).dry_run)

    def test_rejects_bad_values(self) -> None:
        for change in [
            {"DRY_RUN": "yes"},
            {"MAX_LIFETIME_SECONDS": "0"},
            {"MAX_LIFETIME_SECONDS": "24h"},
            {"PROJECT": ""},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                reaper.Config.from_env({**self.ENV, **change})


class ClientError(Exception):
    """The shape of botocore.exceptions.ClientError that reaper reads."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeEC2:
    """Pages from Describe*, a log of mutating calls, and scripted errors."""

    def __init__(self, instances=(), volumes=(), interfaces=(), errors=None) -> None:
        self.pages = {
            "describe_instances": [{"Reservations": [{"Instances": list(instances)}]}],
            "describe_volumes": [{"Volumes": list(volumes)}],
            "describe_network_interfaces": [{"NetworkInterfaces": list(interfaces)}],
        }
        self.filters: dict[str, list] = {}
        self.calls: list[tuple[str, dict]] = []
        # (operation, resource id) -> list of error codes, consumed in order.
        self.errors = errors or {}

    def get_paginator(self, operation: str):
        fake = self

        class Paginator:
            def paginate(self, Filters):
                fake.filters[operation] = Filters
                return fake.pages[operation]

        return Paginator()

    def _mutate(self, operation: str, resource_id: str, kwargs: dict) -> None:
        self.calls.append((operation, kwargs))
        queue = self.errors.get((operation, resource_id), [])
        if queue:
            raise ClientError(queue.pop(0))
        if kwargs.get("DryRun"):
            raise ClientError("DryRunOperation")

    def terminate_instances(self, **kwargs) -> None:
        self._mutate("terminate_instances", kwargs["InstanceIds"][0], kwargs)

    def modify_instance_attribute(self, **kwargs) -> None:
        self._mutate("modify_instance_attribute", kwargs["InstanceId"], kwargs)

    def delete_volume(self, **kwargs) -> None:
        self._mutate("delete_volume", kwargs["VolumeId"], kwargs)

    def create_tags(self, **kwargs) -> None:
        self._mutate("create_tags", kwargs["Resources"][0], kwargs)

    def delete_network_interface(self, **kwargs) -> None:
        self._mutate("delete_network_interface", kwargs["NetworkInterfaceId"], kwargs)


def config(dry_run: bool = False) -> reaper.Config:
    return reaper.Config(project=PROJECT, region="us-west-2", max_lifetime=DAY, dry_run=dry_run)


class RunTest(unittest.TestCase):
    def fleet(self, **kwargs) -> FakeEC2:
        return FakeEC2(
            instances=[instance("i-expired"), instance("i-ok", ExpiresAt="2026-09-24T16:00:00Z")],
            volumes=[volume("vol-old")],
            interfaces=[interface("eni-new"), interface("eni-old", OrphanSeenAt="2026-09-24T11:00:00Z")],
            **kwargs,
        )

    def test_reads_with_server_side_state_filters(self) -> None:
        ec2 = FakeEC2()
        reaper.run(ec2, config(), NOW)
        self.assertEqual(
            ec2.filters["describe_instances"],
            [{"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}],
        )
        self.assertEqual(ec2.filters["describe_volumes"], [{"Name": "status", "Values": ["available"]}])
        self.assertEqual(
            ec2.filters["describe_network_interfaces"], [{"Name": "status", "Values": ["available"]}]
        )

    def test_acts(self) -> None:
        ec2 = self.fleet()
        with self.assertLogs("reaper", "INFO"):
            summary = reaper.run(ec2, config(), NOW)
        self.assertEqual(
            ec2.calls,
            [
                ("terminate_instances", {"DryRun": False, "InstanceIds": ["i-expired"]}),
                ("delete_volume", {"DryRun": False, "VolumeId": "vol-old"}),
                (
                    "create_tags",
                    {
                        "DryRun": False,
                        "Resources": ["eni-new"],
                        "Tags": [{"Key": "OrphanSeenAt", "Value": "2026-09-24T12:00:00Z"}],
                    },
                ),
                ("delete_network_interface", {"DryRun": False, "NetworkInterfaceId": "eni-old"}),
            ],
        )
        self.assertEqual(summary["terminate"], {"i-expired": "no ExpiresAt tag"})
        self.assertEqual(summary["errors"], [])

    def test_dry_run_sends_dry_run_to_every_call_and_succeeds(self) -> None:
        ec2 = self.fleet()
        with self.assertLogs("reaper", "INFO"):
            summary = reaper.run(ec2, config(dry_run=True), NOW)
        self.assertEqual(len(ec2.calls), 4)
        self.assertTrue(all(kwargs["DryRun"] is True for _, kwargs in ec2.calls))
        self.assertTrue(summary["dry_run"])
        self.assertEqual(summary["errors"], [])

    def test_dry_run_reports_missing_permissions(self) -> None:
        ec2 = self.fleet(errors={("delete_volume", "vol-old"): ["UnauthorizedOperation"]})
        with self.assertLogs("reaper", "INFO"), self.assertRaisesRegex(RuntimeError, "1 reaper action"):
            reaper.run(ec2, config(dry_run=True), NOW)

    def test_removes_termination_protection(self) -> None:
        ec2 = FakeEC2(
            instances=[instance("i-protected")],
            errors={("terminate_instances", "i-protected"): ["OperationNotPermitted"]},
        )
        with self.assertLogs("reaper", "INFO"):
            reaper.run(ec2, config(), NOW)
        self.assertEqual(
            [operation for operation, _ in ec2.calls],
            ["terminate_instances", "modify_instance_attribute", "terminate_instances"],
        )
        self.assertEqual(ec2.calls[1][1]["DisableApiTermination"], {"Value": False})

    def test_gone_resources_are_not_errors(self) -> None:
        ec2 = self.fleet(
            errors={
                ("terminate_instances", "i-expired"): ["InvalidInstanceID.NotFound"],
                ("delete_volume", "vol-old"): ["InvalidVolume.NotFound"],
            }
        )
        with self.assertLogs("reaper", "INFO"):
            summary = reaper.run(ec2, config(), NOW)
        self.assertEqual(summary["errors"], [])

    def test_one_failure_does_not_stop_the_other_actions(self) -> None:
        ec2 = self.fleet(errors={("terminate_instances", "i-expired"): ["UnauthorizedOperation"]})
        with self.assertLogs("reaper", "INFO"), self.assertRaises(RuntimeError):
            reaper.run(ec2, config(), NOW)
        self.assertEqual(
            [operation for operation, _ in ec2.calls],
            ["terminate_instances", "delete_volume", "create_tags", "delete_network_interface"],
        )

    def test_non_api_errors_propagate(self) -> None:
        class Broken(FakeEC2):
            def terminate_instances(self, **kwargs) -> None:
                raise KeyError("bug")

        ec2 = Broken(instances=[instance("i-expired")])
        with self.assertRaises(KeyError):
            reaper.run(ec2, config(), NOW)


if __name__ == "__main__":
    unittest.main()
