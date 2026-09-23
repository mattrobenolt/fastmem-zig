# Benchmark system design

This document is the contract for the benchmark system. It replaces
`infra/bench.nu`, the OrbStack target, and the per-box build flow.
Three components implement it: the infrastructure (`infra/`), the
harness (`bench/`), and the measurement binary (`src/bench_fastmem.zig`).
Each component owns its own files. The interfaces between them are
fixed here. Change an interface in this file first, then in the code.

## Goals

1. A benchmark loop that takes minutes: build, ship, run, analyze.
2. Parallel runs across all CPU families, with one command.
3. Results that are repeatable and that record their full provenance.
4. A noise floor that is measured on every run, not assumed.
5. An agent can operate the fleet without a human, and cannot leak money.
6. The generic parts are copyable into other projects (for example
   `~/code/handoff`) without edits.

## Non-goals

- A custom AMI. The official NixOS AMI plus `user_data` is enough for now.
- Multi-region. The fleet is `us-west-2` only.
- A results database. Results are files on the local disk.
- Spot instances. On-demand only.
- Benchmarks of revisions that predate this design. Their binaries do
  not emit the JSONL schema.

## Core decisions

- **Build locally, ship binaries.** The harness cross-compiles every
  binary on the dev machine with Zig. A box receives only binaries. A box
  has no Zig, no repository, and no `nix develop` step.
- **Explicit CPU models.** Each target has an explicit `-Dcpu` value.
  The harness never builds with `native`.
- **State lives in AWS tags.** The harness has no local state file. It
  finds instances by tag. Two harness processes can run at the same time.
- **OpenTofu owns only durable resources.** OpenTofu creates the IAM user,
  the security group, the key pair, and the launch templates. The harness
  launches and terminates instances through the EC2 API.
- **Boxes destroy themselves.** Every instance has an `ExpiresAt` tag.
  A timer on the box powers it off after that time. The launch template
  sets shutdown behavior to `terminate`.

## Targets

| Target | Instance type | ISA | Zig target | `-Dcpu` |
|---|---|---|---|---|
| `c7i` | `c7i.xlarge` | x86_64 | `x86_64-linux-gnu` | `sapphirerapids` |
| `c8i` | `c8i.xlarge` | x86_64 | `x86_64-linux-gnu` | `graniterapids` |
| `c7a` | `c7a.xlarge` | x86_64 | `x86_64-linux-gnu` | `znver4` |
| `c8a` | `c8a.xlarge` | x86_64 | `x86_64-linux-gnu` | `znver5` |
| `c7g` | `c7g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v1` |
| `c8g` | `c8g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v2` |
| `c9g` | `c9g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v3` |

The `-Dcpu` value for `c9g` is unverified. The host facts step records
the real core, and a human corrects the table if it is wrong.

Intel families have two threads for each core. AMD and Graviton families
have one thread for each core. The harness reads the topology from sysfs.
It does not assume it.

A target can also run a "baseline" build (`x86_64_v3` or `generic`).
The target table is data in `bench.toml`, not code.

## Repository layout

```
bench.toml                  project config for the harness
infra/
  iam/                      OpenTofu: IAM user and policy. A human applies it once.
  base/                     OpenTofu: security group, key pair, launch templates.
  image/configuration.nix   NixOS user_data for every box
bench/
  pyproject.toml            uv project
  ec2bench/                 generic fleet library and CLI. No fastmem code.
  fastmem_bench/            fastmem adapter: build, run protocol, analysis
  tests/
src/bench_fastmem.zig       measurement binary
src/libc_probe.zig          libc symbol probe
```

`infra/` and `bench/ec2bench/` are the copyable pattern. A new project
copies both, writes its own `bench.toml`, and writes its own adapter
package.

## AWS account

- Account `396684171460` ("playground"), region `us-west-2`.
- The human bootstrap profile is `playground-ops` (SSO).
- The agent profile is `fastmem-bench`. It holds static keys for the
  IAM user `fastmem-bench`.
- Use the default VPC and its default subnets. Do not create a VPC.

## Tags

Every resource that the system creates has these tags:

| Tag | Value |
|---|---|
| `Project` | `fastmem-bench` (from `bench.toml`, `project.name`) |
| `ManagedBy` | `tofu` or `ec2bench` |

Every instance also has these tags:

| Tag | Value |
|---|---|
| `Name` | `<project>-<target>` |
| `Target` | target name, for example `c8g` |
| `ExpiresAt` | UTC time in RFC 3339 format, for example `2026-09-24T04:00:00Z` |
| `Owner` | free text, for example `agent` or `matt` |

The IAM policy uses the `Project` tag as its security boundary.

## infra/iam

- Create the IAM user `fastmem-bench` with an inline policy and one
  access key. Write the key to the `[fastmem-bench]` profile in
  `~/.aws/credentials` with a script, as `~/code/handoff/infra/iam` does.
- The policy allows all `ec2:Describe*` and `ec2:Get*` actions.
- The policy allows `ec2:RunInstances` only when all of these are true:
  - The request tags the instance and the volume with `Project=fastmem-bench`.
  - The instance type matches the allowlist. The allowlist is
    `c7i.*`, `c8i.*`, `c7a.*`, `c8a.*`, `c7g.*`, `c8g.*`, `c9g.*`.
    It excludes the `-flex` variants. It includes the `.metal` sizes.
  - The request uses a launch template.
- The policy allows `ec2:CreateTags` only during `RunInstances`, or on
  resources that already have `Project=fastmem-bench`.
- The policy allows `ec2:TerminateInstances`, `ec2:StopInstances`, and
  `ec2:StartInstances` only on resources with `Project=fastmem-bench`.
- The policy allows the create and delete actions for security groups,
  key pairs, and launch templates that `infra/base` needs. Scope them by
  tag where EC2 supports tag conditions.
- The policy denies every action outside `us-west-2`
  (`aws:RequestedRegion`), except global actions that need it.
- The policy grants no IAM, S3, or other service. The user cannot
  escalate its own privileges.
- `terraform.tfstate` contains the secret. It stays gitignored.

## infra/base

The `fastmem-bench` profile applies this stack.

- A security group `<project>-ssh` in the default VPC. It allows inbound
  SSH. It allows all outbound traffic.
- An ED25519 key, generated by OpenTofu. The private key goes to
  `infra/base/bench.pem`, mode `0600`, gitignored.
- One launch template for each architecture: `<project>-x86_64` and
  `<project>-arm64`. Each launch template sets:
  - an AMI that is pinned by ID. The initial IDs are the NixOS
    `25.11.12484.b6018f87da91` images: `ami-0e78db03e0a4e1eb0` (x86_64)
    and `ami-0b1109b091092c6fe` (arm64).
  - `instance_initiated_shutdown_behavior = "terminate"`
  - `metadata_options`: IMDSv2 required, `instance_metadata_tags = "enabled"`
  - a gp3 root volume of 20 GiB
  - `user_data` from `infra/image/configuration.nix`
  - tag specifications for instance and volume with `Project` and `ManagedBy`
  - the security group and the key pair
  - no instance type. The harness supplies it.
- Outputs: the launch template IDs by architecture, the key file path,
  the security group ID. The harness reads these with `tofu output -json`.

## infra/image/configuration.nix

- Import the `amazon-image.nix` module. Enable flakes.
- Enable `programs.nix-ld`. The shipped binaries use the interpreter
  `/lib64/ld-linux-x86-64.so.2` or `/lib/ld-linux-aarch64.so.1`.
- Set `kernel.randomize_va_space = 0`, `kernel.perf_event_paranoid = -1`,
  and `kernel.kptr_restrict = 0`.
- Mask noisy services as `~/code/handoff/infra/bench/configuration.nix`
  does. Do not disable `dhcpcd`.
- Install `rsync`, `binutils` (for `objdump`), `util-linux`, `perf`, and
  `jq`.
- Add the TTL guard: a systemd timer that runs every minute. It reads the
  `ExpiresAt` tag from IMDS. If the current time is after `ExpiresAt`,
  it runs `poweroff`. If IMDS has no `ExpiresAt` tag, it uses a fallback
  of 12 hours after boot.
- Write `/etc/bench-image` with an image version string. The harness
  reads this file to know that the first-boot configuration is active.

## bench.toml

```toml
[project]
name = "fastmem-bench"
region = "us-west-2"
profile = "fastmem-bench"
adapter = "fastmem_bench"
remote_dir = "/root/bench"
image_version = "1"          # must match /etc/bench-image on the box

[fleet]
default_ttl = "4h"
default_owner = "agent"

[targets.c7i]
instance_type = "c7i.xlarge"
arch = "x86_64"
zig_target = "x86_64-linux-gnu"
zig_cpu = "sapphirerapids"
# ... one table for each target in the Targets section
```

`ec2bench` reads `[project]`, `[fleet]`, and the `instance_type` and
`arch` fields of `[targets.*]`. The adapter reads the other fields.
`ec2bench` ignores keys that it does not know.

## bench/ec2bench (generic)

`ec2bench` contains no fastmem code. It depends on `boto3`, `rich`, and
`click`. It uses the system `ssh` and `rsync` with SSH connection
multiplexing (`ControlMaster`).

Commands (entry point `bench`, run as `uv run bench <command>`):

| Command | Behavior |
|---|---|
| `up <target>... [--ttl 4h] [--size xlarge]` | Launch the missing instances from the launch templates. Wait until SSH works and `/etc/bench-image` matches. Launch all targets in parallel. |
| `ls` | Show the instances with the `Project` tag: target, type, state, IP, time until `ExpiresAt`. |
| `down <target>... \| --all` | Terminate instances. |
| `extend <target>... --ttl 2h` | Set `ExpiresAt` to now plus the TTL. |
| `reap` | Terminate every instance with the `Project` tag whose `ExpiresAt` is in the past or absent. |
| `ssh <target> [cmd...]` | Open a shell, or run one command. |
| `facts <target>...` | Collect host facts and print them. |

Library responsibilities:

- `Config`: parse `bench.toml`.
- `Fleet`: find instances by tag, launch, terminate, extend, reap.
  One running instance for each target at a time.
- `Box`: SSH command execution with timeout and streamed output, file
  upload, and file download for one instance.
- `parallel`: run one function across boxes at the same time, with a
  `rich` live display for each box. One failed box does not stop the
  others. The caller receives a result or an error for each box.
- Host facts: collect generic facts and cache them by instance ID under
  `bench-results/.facts/<instance-id>.json`. Generic facts are:
  `/proc/cpuinfo` model and flags, `lscpu -J`, CPU topology from sysfs,
  `uname -a`, the kernel command line, the IMDS instance identity document,
  `/etc/bench-image`, and the NixOS version.
- CPU isolation: a function that selects one benchmark CPU for each box.
  It selects the last physical core. On SMT hosts, it also leaves the
  SMT sibling idle. It restricts `system.slice`, `user.slice`, and
  `init.scope` to the other CPUs with `systemctl set-property --runtime`
  `AllowedCPUs=`. It returns the CPU number for `taskset`. A second
  function restores the old state.
- Plugin hook: an adapter registers more `click` commands on the `bench`
  group. `ec2bench` finds the adapter from `bench.toml`
  (`[project] adapter = "fastmem_bench"`).
- Run directories: `bench-results/<run-id>/`. The run ID is
  `<UTC yyyymmddTHHMMSSZ>-<label>`. `manifest.json` holds the git state,
  the command line, the targets, and the instance IDs.

## bench/fastmem_bench (adapter)

Command: `bench run`.

```
bench run [--rev REV]... [--target T]... [--suite quick|standard|dist]
          [--rounds N] [--no-aa] [--up] [--label L]
```

- `--rev` names a git revision. `WORKTREE` names the current working
  tree, uncommitted edits included. The default is `WORKTREE` only.
  With two or more revisions, the first revision is the baseline.
- `--target` defaults to all targets with a running instance.
- `--rounds` defaults to 5.
- `--up` launches missing targets first.

Protocol:

1. Resolve each revision to a source tree. A committed revision gets a
   `git worktree` under `.bench-cache/src/<sha>`. `WORKTREE` uses the
   repository root.
2. Build for each (revision, target) pair:
   `zig build install -Dtarget=<zig_target> -Dcpu=<zig_cpu>
   -Doptimize=ReleaseFast -Dlink-libc=true -Drev=<label> --prefix <dir>`.
   Cache the output by (source hash, target, cpu). Build the pairs in
   parallel, limited to the number of local CPUs.
3. Disassemble the `fastmem_*` and `builtin_*` symbols of each local
   binary with `llvm-objdump`. Save the result in the run directory.
4. For each target, in parallel:
   1. Upload the binaries and `libc-probe` to `<remote_dir>/<run-id>/`.
   2. Collect host facts (cached). Run `libc-probe`. Disassemble the
      resolved glibc `memcpy` and `memmove` implementations on the box.
   3. Isolate the benchmark CPU.
   4. Build the variant list: one variant for each revision, plus an
      `A/A` variant that runs the baseline binary a second time. `--no-aa`
      removes the `A/A` variant.
   5. For each round, shuffle the variant order with a seed that the
      manifest records. Run each variant once with `taskset -c <cpu>`.
      Write stdout to `raw/<variant>/r<round>.jsonl`.
   6. Restore CPU isolation. Download the raw files.
5. Analyze and write `summary.json` and `report.md`. Print the summary
   table.

Analysis:

- The unit of measurement is ns per operation. For each (target, case,
  impl, variant), pool the samples of all rounds and take the median.
- Report these ratios for each case, as `candidate / baseline` of the
  medians:
  - each revision against the baseline revision, for `impl = fastmem`
  - `fastmem` against `libc` and against `builtin`, for each revision
  - `A/A` against the baseline, for the noise floor
- Compute a 95% confidence interval for each ratio with a bootstrap over
  rounds. Use a fixed seed. Use the Python standard library only.
- Mark a ratio as significant only if its interval excludes 1.0 and its
  distance from 1.0 is larger than the `A/A` noise floor of the target.
- Report the geometric mean of the ratios for each (op, size tier). The
  size tiers are 0–16, 17–64, 65–256, 257–1024, 1025–16384, and above
  16384 bytes.
- `report.md` puts one table for each target and marks significant rows.

## Measurement binary: bench-fastmem

The binary measures. It does not format output for humans. Its stdout is
JSONL. Its stderr is free text for diagnostics.

### CLI

```
bench-fastmem [--suite quick|standard|dist] [--filter <substring>]
              [--impl builtin,fastmem,libc] [--samples N]
              [--sample-ms M] [--warmup-ms W] [--seed S] [--list]
```

Defaults: `--suite standard`, all impls that the build includes,
`--samples 5`, `--sample-ms 20`, `--warmup-ms 10`. `--list` prints one
JSON line for each case and runs nothing.

### Cases

A case ID is `<op>/<profile>/<size>`. For `move`, the profile is
`<direction>-gap<gap>`.

- `copy` profiles: `aligned` (source offset 0, destination offset 0),
  `misaligned` (1, 3), and `cross-lane` (`chunk - 1`, `chunk / 2`), where
  `chunk` is the SIMD chunk size.
- `move` profiles: directions `fwd` and `bwd`, gaps 1, `chunk - 1`, and
  `chunk + 1`.
- `standard` sizes: 0, 1, 2, 3, 4, 7, 8, 15, 16, 24, 31, 32, 48, 63, 64,
  96, 127, 128, 192, 255, 256, 384, 511, 512, 768, 1024, 2048, 4096,
  8192, 16384, 65536, 262144, 1048576.
- `quick` sizes: 8, 32, 64, 256, 1024, 4096, 16384, 262144.
- `dist` cases: a fixed pseudo-random sequence of sizes, generated from
  `--seed`, is copied in a loop. Each call has a different size and a
  different offset inside a buffer. The case IDs are `copy/dist/<name>`
  and `move/dist/<name>`. The distributions are `small` (sizes 0–256,
  weighted to small sizes) and `mixed` (sizes 0–16384, log-uniform).
  The `ns` field is per call. `size` is the mean size.
- A full `standard` run of one binary on one host takes 4 minutes or
  less. A `quick` run takes 1 minute or less.

Buffers come from page-aligned heap memory. The loop mutates the source
and reads the destination so that the compiler cannot remove the copy.
The existing `runCopyOnce` loop shows the method.

Inside one case, the binary rotates the impl order for each sample. This
cancels slow drift between impls.

### Performance counters

On Linux, the binary opens a `perf_event_open` group for the benchmark
thread: `cycles`, `instructions`, and on x86 also `ref-cycles`. It counts
user space only. If the kernel refuses the group, the counter fields are
`null` and the meta line records the error. The binary does not fail.

### JSONL schema, version 1

The first line is the meta record:

```json
{"type":"meta","schema":1,"rev":"<-Drev value>","zig":"0.16.0",
 "target":"x86_64-linux-gnu","cpu":"sapphirerapids","optimize":"ReleaseFast",
 "link_libc":true,"chunk_bytes":32,"suite":"standard","seed":1,
 "samples":5,"sample_ms":20,"warmup_ms":10,"impls":["builtin","fastmem","libc"],
 "perf":{"available":true,"events":["cycles","instructions","ref-cycles"],"error":null}}
```

Each sample is one line:

```json
{"type":"sample","case":"copy/aligned/64","op":"copy","profile":"aligned",
 "size":64,"src_off":0,"dst_off":0,"gap":null,"impl":"fastmem","sample":0,
 "iters":1048576,"ns":12345678,"cycles":40000000,"instructions":9000000,
 "ref_cycles":null}
```

`ns`, `cycles`, `instructions`, and `ref_cycles` are totals for `iters`
operations. The last line is `{"type":"end","cases":<n>,"elapsed_ns":<n>}`.
A consumer rejects a file without an `end` line.

### build.zig

- `-Drev=<string>`: a build option that the binary reports in `meta`.
  The default is `unknown`.
- `zig build install` installs `bench-fastmem` and `libc-probe` for the
  selected `-Dtarget` and `-Dcpu`. `libc-probe` uses the selected target,
  not the host.
- `zig build bench` builds and runs locally, as before.

### libc-probe

`libc-probe` prints one JSON object: the resolved path of libc, the glibc
version (`gnu_get_libc_version`), and for `memcpy` and `memmove` the
runtime address, the symbol name from `dladdr`, and the offset from the
libc base. The harness disassembles the implementation at that offset.
