from datetime import UTC, datetime, timedelta
from typing import Any

import boto3
from moto import mock_aws

from ec2bench.config import Config
from ec2bench.fleet import Fleet, expiry, reap_candidates, tags


def instance(identifier: str, expires: str | None) -> dict[str, Any]:
    return {
        "InstanceId": identifier,
        "Tags": [] if expires is None else [{"Key": "ExpiresAt", "Value": expires}],
    }


def test_reap_selection() -> None:
    now = datetime(2026, 9, 23, tzinfo=UTC)
    instances = [
        instance("old", "2026-09-22T00:00:00Z"),
        instance("missing", None),
        instance("bad", "yesterday"),
        instance("naive", "2026-09-25T00:00:00"),
        instance("equal", "2026-09-23T00:00:00Z"),
        instance("future", "2026-09-24T00:00:00Z"),
    ]
    assert reap_candidates(instances, now) == ["old", "missing", "bad", "naive", "equal"]
    assert expiry("2026-09-23T02:00:00+02:00") == now


@mock_aws
def test_fleet(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    template = client.create_launch_template(
        LaunchTemplateName="test", LaunchTemplateData={"ImageId": "ami-12345678"}
    )
    template_id = template["LaunchTemplate"]["LaunchTemplateId"]
    outputs = {"launch_template_ids": {"x86_64": template_id, "arm64": template_id}}
    fleet = Fleet(config, client)
    assert fleet.instances() == []
    launched = fleet.launch("intel", "4h", "2xlarge", outputs)
    assert launched["InstanceType"] == "c7i.2xlarge"
    assert tags(launched)["Project"] == "test-bench"
    assert tags(launched)["ManagedBy"] == "ec2bench"
    assert tags(launched)["Owner"] == "agent"
    expires = expiry(tags(launched)["ExpiresAt"])
    assert expires is not None
    assert expires > datetime.now(UTC) + timedelta(hours=3)
    assert fleet.launch("intel", "4h", None, outputs)["InstanceId"] == launched["InstanceId"]
    assert len(fleet.instances()) == 1
    client.run_instances(ImageId="ami-12345678", MinCount=1, MaxCount=1, InstanceType="c7i.xlarge")
    assert len(fleet.instances()) == 1
    fleet.extend(["intel"], "2h")
    extended = expiry(tags(fleet.one("intel"))["ExpiresAt"])
    assert extended is not None
    assert timedelta(hours=1) < extended - datetime.now(UTC) <= timedelta(hours=2)
    client.delete_tags(Resources=[launched["InstanceId"]], Tags=[{"Key": "ExpiresAt"}])
    assert fleet.reap() == [launched["InstanceId"]]
    assert fleet.instances() == []


@mock_aws
def test_duplicate_convergence(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    response = client.run_instances(
        ImageId="ami-12345678",
        InstanceType="c7i.xlarge",
        MinCount=2,
        MaxCount=2,
        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Project", "Value": "test-bench"},
                    {"Key": "Target", "Value": "intel"},
                ],
            }
        ],
    )
    instances = response["Instances"]
    fleet = Fleet(config, client)
    expected = min(instances, key=lambda item: (item["LaunchTime"], item["InstanceId"]))
    assert (
        fleet.converge("intel", list(reversed(instances)))["InstanceId"] == expected["InstanceId"]
    )
    assert [item["InstanceId"] for item in fleet.instances()] == [expected["InstanceId"]]
