# infra

This directory holds the durable AWS resources and the box image of the
benchmark fleet. The harness in `bench/` launches and terminates the
instances through the EC2 API. `docs/bench-design.md` is the contract.

## Layout

| Path | Content | Who applies it |
|---|---|---|
| `iam/` | OpenTofu: the IAM user, its EC2 policy, one access key | A human, one time |
| `iam/write-credentials.sh` | Writes the access key to `~/.aws/credentials` | A human |
| `base/` | OpenTofu: security group, key pair, launch templates | The bench profile |
| `image/configuration.nix` | NixOS configuration that every box applies on first boot | `base/` puts it in `user_data` |

## Configuration sources

Both stacks read the `[project]` table of `bench.toml` at the repository root:

- `name` (`fastmem-bench`) names the IAM user and the resources. It is also
  the value of the `Project` tag.
- `profile` (`fastmem-bench`) names the credentials profile. Only
  `write-credentials.sh` uses it.

The region is `us-west-2`. Each stack sets it in `locals`. The account is
`396684171460`. The `account_id` variable sets it, and the AWS provider
refuses every other account.

The instance allowlist is the `instance_families` variable in
`iam/variables.tf`. It does not come from `bench.toml`. The agent can edit
`bench.toml`, and a cost control must not follow a file that the agent edits.

## Prerequisites

- Run each command from the repository root.
- Run each tool from the devshell. Enter it with `nix develop`, or put
  `nix develop -c` before each command.
- Make sure that `bench.toml` exists. Both stacks fail without it.

## Bootstrap the account

Do this procedure one time. It needs a human with the `playground-ops`
SSO profile.

1. Log in to the bootstrap profile:

   ```sh
   aws sso login --profile playground-ops
   ```

2. Make sure that no old security group has the name `fastmem-bench-ssh`
   in the default VPC:

   ```sh
   AWS_PROFILE=playground-ops aws ec2 describe-security-groups --region us-west-2 \
     --filters Name=group-name,Values=fastmem-bench-ssh --query 'SecurityGroups[].[GroupId,VpcId]'
   ```

3. If the command shows a group in the default VPC, and no instance uses
   it, delete it:

   ```sh
   AWS_PROFILE=playground-ops aws ec2 delete-security-group --region us-west-2 --group-id <id>
   ```

4. Apply the IAM stack:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam init
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam apply
   ```

5. Write the credentials profile:

   ```sh
   infra/iam/write-credentials.sh
   ```

6. Wait 10 seconds. A new access key is not valid immediately.

7. Make sure that the profile works:

   ```sh
   AWS_PROFILE=fastmem-bench aws sts get-caller-identity
   ```

   The `Arn` field must be `arn:aws:iam::396684171460:user/fastmem-bench`.

8. Optional: check the policy with IAM Access Analyzer. Findings of type
   `ERROR` or `SECURITY_WARNING` need a fix.

   ```sh
   arn=$(tofu -chdir=infra/iam output -raw policy_arn)
   version=$(AWS_PROFILE=playground-ops aws iam get-policy --policy-arn "$arn" \
     --query Policy.DefaultVersionId --output text)
   AWS_PROFILE=playground-ops aws iam get-policy-version --policy-arn "$arn" \
     --version-id "$version" --query PolicyVersion.Document >/tmp/bench-policy.json
   AWS_PROFILE=playground-ops aws accessanalyzer validate-policy --region us-west-2 \
     --policy-type IDENTITY_POLICY --policy-document file:///tmp/bench-policy.json
   ```

## Apply the base stack

The bench profile applies this stack. A human or an agent can do it.

1. Apply the stack:

   ```sh
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base init
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base apply
   ```

2. Make sure that the outputs exist:

   ```sh
   tofu -chdir=infra/base output -json
   ```

The apply writes the SSH private key to `infra/base/bench.pem` with mode
`0600`. The harness reads these outputs:

| Output | Value |
|---|---|
| `launch_template_ids` | Map from architecture (`x86_64`, `arm64`) to launch template ID |
| `key_file` | Absolute path of `bench.pem` |
| `security_group_id` | ID of the SSH security group |

## Change the box image

1. Edit `infra/image/configuration.nix`.

2. Make sure that the file evaluates against the channel of the AMI.
   Do this for `x86_64-linux` and for `aarch64-linux`:

   ```sh
   nix eval --impure --raw \
     -I nixpkgs=https://releases.nixos.org/nixos/25.11/nixos-25.11.12484.b6018f87da91/nixexprs.tar.xz \
     --expr '(import <nixpkgs/nixos> { configuration = ./infra/image/configuration.nix; system = "x86_64-linux"; }).config.system.build.toplevel.drvPath'
   ```

3. If the change matters to the harness, increase `imageVersion` in the
   file. Set `image_version` in `bench.toml` to the same value.

4. Apply the base stack. The apply adds a new version to each launch
   template.

5. Terminate the boxes. Old boxes keep the old configuration.

   ```sh
   uv run bench down --all
   ```

## Change an AMI

1. Find the new NixOS AMIs. The publisher account is `427812963091`:

   ```sh
   AWS_PROFILE=fastmem-bench aws ec2 describe-images --region us-west-2 --owners 427812963091 \
     --filters 'Name=name,Values=nixos/25.11*' \
     --query 'sort_by(Images,&CreationDate)[-4:].[ImageId,Name,Architecture]' --output table
   ```

2. Set the IDs in `local.amis` in `infra/base/main.tf`.

3. If the NixOS release changes, change these values to the new release:
   - `system.stateVersion` in `infra/image/configuration.nix`
   - the channel URL in the evaluation step of "Change the box image"
   - the comment above `local.amis`

4. Do the procedure "Change the box image" from step 2.

## Change the instance allowlist

1. Edit `instance_families` in `infra/iam/variables.tf`.
2. Apply the IAM stack with the `playground-ops` profile.

## Rotate the access key

1. Replace the key:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam apply -replace=aws_iam_access_key.bench
   ```

2. Write the credentials profile again:

   ```sh
   infra/iam/write-credentials.sh
   ```

## Tear down

1. Terminate all boxes:

   ```sh
   uv run bench down --all
   ```

2. Destroy the base stack:

   ```sh
   AWS_PROFILE=fastmem-bench tofu -chdir=infra/base destroy
   ```

3. Destroy the IAM stack:

   ```sh
   AWS_PROFILE=playground-ops tofu -chdir=infra/iam destroy
   ```

4. Remove the `[fastmem-bench]` section from `~/.aws/credentials`.

## Test the stacks offline

The tests use mock providers. They need no AWS credentials, and they create
no files.

```sh
tofu -chdir=infra/iam init -backend=false
tofu -chdir=infra/iam test
tofu -chdir=infra/base init -backend=false
tofu -chdir=infra/base test
```

## The TTL guard

Every box runs `bench-ttl-guard.timer` one time each minute. The service
gets an IMDSv2 token and reads the `ExpiresAt` instance tag from
`http://169.254.169.254/latest/meta-data/tags/instance/ExpiresAt`.

- If the tag is an RFC 3339 UTC time, the guard uses it.
- If the tag is absent or has a different format, the guard uses boot time
  plus 12 hours.
- If IMDS does not answer, the guard uses the last value that it read. If it
  has no value, it uses boot time plus 12 hours.
- If the current time is after the limit, the guard runs `poweroff`. The
  launch template sets shutdown behavior to `terminate`, so EC2 deletes the
  instance and its volume.

To examine the guard on a box, use these commands:

```sh
systemctl list-timers bench-ttl-guard.timer
journalctl -u bench-ttl-guard.service
```

## The IAM policy

`infra/iam/policy.tf` has one comment for each statement. The `Project` tag
is the security boundary. The bench user can do these things:

- Describe and get all EC2 resources in `us-west-2`.
- Launch instances from a project launch template. The request must tag the
  instance and the volume with `Project`, and the instance with `ExpiresAt`.
  The instance type must be in the allowlist. The AMI, the security group,
  and the key pair must come from the launch template. The AMI must come
  from the NixOS publisher. Volumes are gp3, 100 GiB or smaller.
- Tag project resources. It cannot change the `Project` value, and it
  cannot remove the `Project` or `ExpiresAt` tags.
- Terminate, stop, and start project instances.
- Create, change, and delete the security group, the key pair, and the
  launch templates of `infra/base`. It can create security groups only in the
  default VPC.

The policy grants no IAM, S3, or other service. It denies all actions
outside `us-west-2`. The user has no `iam:PassRole`, so an instance cannot
get an instance profile.

The policy cannot control `user_data` or the shutdown behavior of a request.
A request that overrides them can launch a box without the TTL guard. Run
`uv run bench reap` to terminate such boxes.

The policy is a customer managed policy. IAM limits the inline policies of a
user to 2,048 characters in total, and this policy is larger.

## Fault isolation

- If an EC2 call fails with `UnauthorizedOperation` and an encoded message,
  decode the message with the bootstrap profile:

  ```sh
  AWS_PROFILE=playground-ops aws sts decode-authorization-message \
    --encoded-message <message> --query DecodedMessage --output text | jq .
  ```

- If a box does not become ready, read its console output. Then terminate
  the box.

  ```sh
  AWS_PROFILE=fastmem-bench aws ec2 get-console-output --region us-west-2 \
    --instance-id <id> --latest --output text
  ```

- If the base apply fails with `InvalidGroup.Duplicate`, do steps 2 and 3 of
  "Bootstrap the account".

## Copy into another project

1. Copy `infra/` and `bench/ec2bench/` into the other repository.
2. Write its `bench.toml`. Set `name` and `profile` in `[project]`.
3. If the project uses other instance families, edit `instance_families`
   in `infra/iam/variables.tf`.
4. If the project uses another AWS account, set `account_id` in both stacks.
5. Do the procedures "Bootstrap the account" and "Apply the base stack".
