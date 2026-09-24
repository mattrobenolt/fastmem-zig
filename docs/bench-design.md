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
  modules/bench-iam/        OpenTofu module: IAM user, policy, reaper Lambda
  modules/bench-base/       OpenTofu module: security group, key pair,
                            launch templates, box NixOS configuration
  iam/                      root stack for bench-iam. A human applies it.
  base/                     root stack for bench-base. The bench user applies it.
  base/image.nix            project NixOS module (fastmem packages)
  README.md                 runbook
bench/
  pyproject.toml            uv project
  ec2bench/                 generic fleet library and CLI. No fastmem code.
  fastmem_bench/            fastmem adapter: build, run protocol, analysis
  tests/
src/bench_fastmem.zig       measurement binary
src/libc_probe.zig          libc symbol probe
```

`infra/modules/` and `bench/ec2bench/` are the copyable pattern. They
version as one unit: the Python assumes the tags and the outputs that the
modules produce. They stay in this repository until a second project
(handoff) adopts them. Then they move to their own repository, and
projects pin a tag (`git::...//modules/bench-base?ref=v0.1` and a uv git
dependency).

The root stacks pin provider versions and commit their lock files. The
modules declare only minimum versions.

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

A RunInstances request tags the instance, its volumes, and its network
interfaces. Tag keys must have exactly these spellings: the IAM policy
rejects other keys, in any case. The IAM policy uses the `Project` tag as
its security boundary.

## Lifetime guarantee

Two mechanisms end a box. They are independent.

1. The TTL guard on the box (fast path). A systemd timer reads `ExpiresAt`
   from instance metadata every minute and runs `poweroff`. The launch
   template sets shutdown behavior to `terminate`. The guard falls back to
   12 hours after boot when the tag is missing or malformed.
2. The reaper (the guarantee). A Lambda in the bench-iam module runs every
   5 minutes, outside every box. It terminates each project instance that
   is stopped, has no valid `ExpiresAt`, is past `ExpiresAt`, or is older
   than 24 hours. It deletes orphaned project volumes and network
   interfaces.

The agent can apply `infra/base`, so it can change launch templates, and
it can write any `ExpiresAt` value. The guest guard therefore does not
bind the agent. The reaper does: its role, schedule, and limits belong to
the human-applied stack. The worst case is one allowed instance for 24
hours. The harness caps a TTL at `fleet.max_ttl` (12 hours).

## infra/modules/bench-iam

- An IAM user with one customer managed policy and one access key.
  `infra/iam/write-credentials.sh` writes the key to the profile.
- The policy allows every `ec2:Describe*` and `ec2:Get*` action.
- `ec2:RunInstances` requires: a project launch template, the NixOS AMI
  from that template, the `Project` and `ExpiresAt` request tags, an
  allowed instance family (`c7i`, `c8i`, `c7a`, `c8a`, `c7g`, `c8g`,
  `c9g`, all sizes, no variants), on-demand market, default tenancy, gp3
  volumes up to 100 GiB, 3000 IOPS and 125 MiB/s, and project tags on new
  network interfaces.
- Tag writes need canonical tag keys. Nobody can delete `Project` or
  `ExpiresAt`, in any case.
- `ec2:TerminateInstances` only on project instances. No Stop or Start:
  a stopped instance escapes the guest guard.
- Create, change, and delete of the security group, key pair, and launch
  templates that bench-base needs, scoped by the project tag.
- Every action outside `us-west-2` is denied. No IAM, S3, Lambda, or
  other service. No `iam:PassRole`.
- The reaper Lambda, its role, its log group, and its schedule.
  `infra/README.md` describes the checks after an apply.

## infra/modules/bench-base

- A security group `<project>-ssh` in the default VPC, with inbound SSH.
- An ED25519 key pair. The private key goes to `var.key_file`, mode
  `0600`, gitignored.
- One launch template per architecture (`<project>-x86_64`,
  `<project>-arm64`): a pinned AMI, shutdown behavior `terminate`, IMDSv2
  with instance metadata tags, a gp3 root volume, tag specifications for
  instances, volumes, and network interfaces, and no instance type.
- The user_data is `image.nix.tftpl`, rendered with `var.image_version`
  and the project module `var.nixos_module`. The template owns the fleet
  contract: the TTL guard, `programs.nix-ld` (the shipped binaries use the
  standard interpreter paths), ASLR off, perf sysctls, masked noisy
  services, and `/etc/bench-image`. The project module adds packages.
- Outputs: `launch_template_ids` (by architecture), `key_file`,
  `security_group_id`. The harness reads them with `tofu output -json`.

## bench.toml

```toml
[project]
name = "fastmem-bench"
region = "us-west-2"
profile = "fastmem-bench"
adapter = "fastmem_bench"
remote_dir = "/root/bench"
image_version = "1"          # must match /etc/bench-image on the box
# Optional, with these defaults (they make ec2bench layout-independent):
tofu_dir = "infra/base"
key_output = "key_file"
templates_output = "launch_template_ids"
ssh_user = "root"
results_dir = "bench-results"
cache_dir = ".bench-cache"
minimum_effect = 0.0         # adapter: minimum fractional effect for marks

[fleet]
default_ttl = "4h"
max_ttl = "12h"              # up and extend refuse a longer TTL
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
| `up <target>... [--ttl 4h] [--size xlarge]` | Reap first. Launch the missing instances from the launch templates, in parallel. Wait until SSH works and `/etc/bench-image` matches. Terminate a box that does not become ready. |
| `ls` | Show the instances with the `Project` tag: target, type, state, IP, time until `ExpiresAt`. |
| `down <target>... \| --all` | Terminate instances. |
| `extend <target>... --ttl 2h` | Set `ExpiresAt` to now plus the TTL. |
| `reap` | Terminate every instance with the `Project` tag whose `ExpiresAt` is in the past or absent. |
| `ssh <target> [cmd...]` | Open a shell, or run one command. |
| `facts <target>...` | Collect host facts and print them. |
| `analyze <run-dir>` | Analyze saved raw rounds again, without AWS, SSH, or builds (adapter command). |

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
  `/etc/bench-image`, and the NixOS version. Each probe is optional: a
  failure goes into the facts record and never stops a run.
- CPU isolation: a function that selects one benchmark CPU for each box.
  It selects the last physical core. On SMT hosts, it also leaves the
  SMT sibling idle. It restricts `system.slice`, `user.slice`, and
  `init.scope` to the other CPUs with `systemctl set-property --runtime`
  `AllowedCPUs=`. It returns the CPU number. A directory in `/run` is an
  atomic claim, and an active `ec2bench-run-*` unit means "box busy".
  `run_isolated` executes a command as a transient `ec2bench-run-<name>`
  unit in `bench.slice` on that CPU (the SSH session itself stays in the
  restricted `user.slice`). `stop_isolated` stops a group of these units
  after an interrupt. The old state is restored on exit.
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
          [--filter S] [--impl a,b] [--samples N] [--sample-ms M]
          [--minimum-effect F]
```

- `--rev` names a git revision. `WORKTREE` names the current working
  tree, uncommitted edits included. The default is `WORKTREE` only.
  With two or more revisions, the first revision is the baseline.
- `--target` defaults to all targets with a running instance.
- `--rounds` defaults to 5.
- `--up` launches missing targets first, and measures the targets that
  came up.
- `--filter`, `--impl`, `--samples`, and `--sample-ms` go to the binary.
  Prefer fewer samples and more rounds: rounds are the bootstrap unit.

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
   5. For each round, order the variants by a seeded, balanced Latin
      square row that the manifest records. Run each variant once with
      `run_isolated`. Write stdout to `raw/<variant>/r<round>.jsonl`.
      Download and validate each round file as soon as it finishes; a
      bad file fails that target at once.
   6. On any exit, stop the run's units and restore CPU isolation.
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
- The noise floor is per (target, op, size): the largest A/A departure
  from 1.0, CI endpoints included, pooled across profiles and all impls.
  `dist` cases use one floor per (op, size tier).
- Mark a ratio as significant only if its interval excludes 1.0, its
  distance from 1.0 is larger than its floor and `minimum_effect`, and
  the run has at least 5 rounds. With 3 rounds, the bootstrap interval is
  the per-round range and covers about 78%.
- Revisions with different case sets are compared on their common cases,
  with a warning.
- Report the geometric mean of the ratios for each (op, size tier). The
  size tiers are 0–16, 17–64, 65–256, 257–1024, 1025–16384, and above
  16384 bytes.
- `report.md` puts one table for each target and marks significant rows.

## Measurement binary: bench-fastmem

This section defines schema v2 and supersedes the adapter comparisons above.
The implementation is `src/bench_fastmem.zig`.
The parser is `bench/fastmem_bench/jsonl.py`.
The native integration tests are `bench/tests/test_binary_v2.py`.

The binary writes JSONL to stdout and diagnostics to stderr.
It retains samples until the run ends, so the first record includes all performance counter errors.
An interrupted run has no complete JSONL artifact.

### CLI

```text
bench-fastmem [--suite quick|standard|large|const|dist]
              [--filter <substring>]...
              [--impl builtin,glibc,fastmem_abi,fastmem_inline,builtin_const]
              [--samples N] [--sample-ms M] [--warmup-ms W]
              [--seed S] [--dist-file <path>] [--list]
```

The defaults are `standard`, all applicable implementations, 20 ms per sample, 10 ms warmup, and seed 1.
The default sample count is the least common multiple of the applicable implementation counts across selected cases.
An unfiltered standard or quick run uses four samples.
A const run uses two samples.
An explicit `--samples` value overrides balance.

The filter selects case IDs by substring.
Multiple filters form a union.
The parser accepts both `--flag value` and `--flag=value`.
Empty selections and invalid arguments cause a nonzero exit.

### Implementations and resolution

| Name | Operation |
|---|---|
| `builtin` | The validated `@extern` pointer to compiler-rt `memcpy`, `memmove`, or `memset` |
| `glibc` | The function pointer from `dlopen("libc.so.6")` and `dlsym` |
| `fastmem_abi` | The public fastmem API in a noinline C-ABI wrapper |
| `fastmem_inline` | The public fastmem API directly in the timed loop |
| `builtin_const` | `@memcpy` with a comptime-known length directly in the timed loop |

The three indirect implementations share one timed loop for each operation.
A volatile load reads the selected function pointer once before each batch.
The loop calls that pointer for each operation.
The const profile compares only `builtin_const` and `fastmem_inline`.

The public API does not yet provide `fastmem.set`.
Consequently, set cases contain only `builtin` and `glibc` samples.
The meta field `fastmem_set` records this absence.
The compile-time declaration check enables both fastmem set paths when that API exists.

At startup, `dlinfo(RTLD_DI_LINKMAP)` identifies the library that `dlopen` returns.
Each glibc pointer must have the same `dladdr` path and base as that library.
The path must end with `/libc.so.6`.
The library base must differ from the executable base.

The builtin evidence comes from `@extern` addresses for `memcpy`, `memmove`, and `memset`.
Each address must resolve to the executable, not libc.
A failed invariant causes a nonzero exit and an error on stderr.
The build includes compiler-rt explicitly.
Builtin wrappers remain only for the codegen proof.
The timed builtin path calls their resolved callees directly, without the extra wrapper.
The harness binary check proves that each builtin wrapper calls the corresponding local text symbol.

The inline and ABI paths call the existing public fastmem API without kernel modifications.
These names identify call boundaries, not independent kernel implementations.

### Cases and buffers

A fixed-size case ID is `<op>/<profile>/<size>`.
The operation is `copy`, `move`, or `set`.

| Operation | Profiles |
|---|---|
| copy | `aligned`: offsets 0/0, `misaligned`: offsets 1/3, `cross-lane`: offsets `chunk-1`/`chunk/2`, `page-offset`: offsets 0/2048 |
| move | `disjoint`, plus `fwd-gapN` and `bwd-gapN` for gaps 1, `chunk-1`, and `chunk+1` |
| set | `aligned`: destination offset 0, `misaligned`: destination offset 3 |

Forward move places the destination below the source.
Backward move places the destination above the source.
The requested gap remains fixed even when the size does not exceed it.
Such small cases do not overlap.
Disjoint move uses separate mappings.

The standard runtime sizes are:

```text
0, 1, 2, 3, 4, 7, 8, 15, 16, 24, 31, 32, 48, 63, 64, 96,
127, 128, 192, 255, 256, 384, 511, 512, 768, 1024, 2048,
4096, 8192, 16384, 65536, 262144, 1048576
```

The quick runtime sizes are:

```text
8, 32, 64, 256, 1024, 4096, 16384, 262144
```

The large runtime sizes are 1, 4, 16, and 64 MiB.
Large remains a separate suite.
The const suite uses the `copy/const/<size>` profile at these sizes:

```text
1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256
```

The standard suite also includes all const cases and both synthetic distributions for every operation.
With the current API, standard contains 448 cases and quick contains 104 cases.
These counts follow the construction in `buildCases` and the native coverage test.

All buffers come from page-aligned anonymous `mmap` mappings sized for the case.
Fixed mappings include their maximum offset plus one additional byte.
Distribution mappings include 512 additional bytes for their offsets.
The `page-offset` profile separates the source and destination offsets modulo 4096 by 2048 bytes.
The loop does not mutate source bytes between operations.
Copy and move read a destination byte after each operation.
Set writes the nonzero byte 165 and reads a destination byte.
A memory clobber preserves the entire inline operation, not only the observed byte.
There is no accumulated checksum or checksum dependency between iterations.

### Distributions

A distribution contains 4096 seeded entries with sizes and offsets.
The loop repeats that sequence.
The sample field `size` is its arithmetic mean.
The `ns` field remains a total over `iters` calls, not a per-call value.

| Case suffix | Size distribution | Offset range |
|---|---|---|
| `dist/small` | Minimum of two uniform draws from 0 through 256 | 0 through 127 |
| `dist/mixed` | Log-uniform sizes from 0 through 16384 | 0 through 511 |
| `dist/file` | Weighted draws from the supplied histogram | 0 through 511 |

Distribution copy uses separate source and destination mappings.
Distribution move uses independently selected offsets in one shared mapping.
Distribution set ignores the source offset.

The option `--dist-file` requires `--suite dist` and replaces the synthetic distributions.
Its JSON format is `{"<size>": weight, ...}`.
Sizes are integer byte counts from zero through 1 GiB.
Weights are finite, nonnegative numbers, with a positive total.
The file limit is 1 MiB.

The adapter accepts `--dist-file`, saves its bytes and SHA-256 digest, and uploads the file with the binary.
The manifest records the original path and digest.
The meta record contains the path that the binary reads.

### Calibration and sample order

Each implementation starts with a 64-iteration pilot after its warmup.
Calibration scales the batch both downward and upward toward the requested sample duration.
It stops within 25 percent, after 12 attempts, or at the iteration limits.
The limits are one operation and 1073741824 operations.
A single slow operation can exceed the duration target.

Each recorded sample contains its actual iteration count.
The next sample uses a proportional adjustment from the previous duration.
Within a case, sample `s` starts at implementation index `s % count`.
This rotation balances positions when the sample count is a multiple of the implementation count.

### Performance counters

The Linux group contains cycles, instructions, and x86 ref-cycles.
The group counts the benchmark thread and excludes kernel and hypervisor execution.
Its read format is `GROUP | TOTAL_TIME_ENABLED | TOTAL_TIME_RUNNING`.
Every reset, enable, and disable ioctl uses `PERF_IOC_FLAG_GROUP`.
Every ioctl result is checked.

The sample stores unscaled event counts.
The fields `time_enabled` and `time_running` expose multiplexing in nanoseconds.
They are per-sample deltas because `PERF_EVENT_IOC_RESET` does not reset those kernel time fields.
The group reset does reset all event counts.

A ref-cycles open failure retries the group with only cycles and instructions.
The meta error names the failed event, and `perf.events` names the retained group.
A successful retry keeps `perf.available` true.
Other open failures and all ioctl or read failures disable the group for the rest of the run.
Affected samples contain null counter and time fields.
Earlier successful samples retain their counts.
The meta record contains the error and sets `perf.available` to false.
The consecutive-sample test skips when the host denies access or supplies no PMU runtime.

### JSONL schema, version 2

Every measurement consists of one meta record, sample records, and one end record.
The parser rejects schema v1 and files without an end record.
It also rejects duplicate samples and incomplete per-case implementation sets.
All record objects reject unknown fields and duplicate JSON keys.
Integer fields reject floats, strings, and booleans.
Cross-field checks enforce case IDs, sizes, offsets, gaps, suites, and perf event consistency.

Meta fields:

| Field | Type and meaning |
|---|---|
| `type`, `schema` | Literal `"meta"` and integer 2 |
| `rev`, `zig`, `target`, `cpu`, `optimize` | Build identifiers. Optimize is `"ReleaseFast"`. |
| `link_libc`, `chunk_bytes` | Literal true and the SIMD chunk size |
| `suite`, `seed`, `samples`, `sample_ms`, `warmup_ms` | Effective configuration |
| `impls` | Selected implementation names applicable to at least one selected case |
| `dist_file` | String path or null |
| `set_value`, `fastmem_set` | Integer 165 and the availability of the public set API |
| `libc_path`, `libc_base` | The `dlopen` library path and integer base address |
| `resolution` | Objects for `memcpy`, `memmove`, and `memset` |
| `perf` | Object with `available`, `events`, and `error` |

Each resolution object contains `glibc` and `builtin` evidence objects.
Each evidence object contains these fields:

| Field | Type and meaning |
|---|---|
| `address` | Positive integer function pointer |
| `dli_fname` | Nonempty library or executable path |
| `dli_fbase` | Positive integer base address |
| `offset` | Nonnegative integer `address - dli_fbase` |

The `perf.events` list names the final attempted group, including any ref-cycles fallback.
The `perf.error` field is a diagnostic string or null.
The `perf.available` field is true when the final group remains usable throughout the run.

A sample has this shape. The numbers are illustrative, not benchmark evidence.

```json
{"type":"sample","case":"copy/aligned/64","op":"copy","profile":"aligned","size":64,"src_off":0,"dst_off":0,"gap":null,"impl":"fastmem_abi","sample":0,"iters":1000,"ns":10000,"cycles":30000,"instructions":9000,"ref_cycles":null,"time_enabled":11000,"time_running":11000}
```

Sample fields:

| Field | Type and meaning |
|---|---|
| `case`, `op`, `profile` | Case identity and operation metadata |
| `size` | Nonnegative number. Fixed size or distribution mean, in bytes. |
| `src_off`, `dst_off` | Nonnegative integers for fixed cases, null for distributions |
| `gap` | Integer for a fixed directional move, otherwise null |
| `impl` | One applicable implementation name |
| `sample` | Zero-based sample index within this case and implementation |
| `iters` | Positive integer operation count |
| `ns` | Positive integer elapsed nanoseconds for the batch |
| `cycles`, `instructions`, `ref_cycles` | Nonnegative integer totals or null |
| `time_enabled`, `time_running` | Nonnegative integer nanoseconds or null |

On aarch64, `ref_cycles` is always null.
The source offset has no operational meaning for set.
Consumers compute ns per operation as `ns / iters`.
They do not scale wall-clock time with the PMU time fields.

The end record has this shape:

```json
{"type":"end","cases":104,"elapsed_ns":123456789}
```

The field `cases` counts selected cases, not samples.
The field `elapsed_ns` includes warmup, calibration, and measurements, but excludes JSON emission.
With `--list`, case records replace samples.
A case record has `type`, `case`, `op`, `profile`, and `size` fields.
The analysis parser does not accept list output as a measurement.

### Adapter comparisons and goals

The schema-v2 adapter reports these comparisons for each common case:

- `builtin/glibc`: the ecosystem gap.
- `fastmem_abi/glibc`: the G2 kernel comparison.
- `fastmem_inline/glibc`: the G4 inline comparison.
- `fastmem_abi/builtin`: the G3 compiler-rt comparison.
- `fastmem_inline/builtin_const`: the const comparison.
- Each fastmem implementation against itself in the baseline revision.

Ratios use candidate time divided by reference time.
The adapter retains the round bootstrap and per-operation, per-size A/A floors described above.
Significance requires at least five rounds and an available A/A floor.
Distribution floors remain per operation and size tier.

Both output files contain a Goals section for each target, revision, and operation.
The machine representation is `targets.<target>.goals` in `summary.json`.
Each entry contains `G2`, `G3`, and `G4` objects with PASS, FAIL, or NA status.
Missing cases, fewer than five rounds, or absent A/A evidence produce NA for the affected component.

G2 uses only the fixed standard runtime cases.
Its evidence includes the overall geometric mean, tier means, and significant regressions above 1.10.
A significant regression above a threshold requires a confidence interval above that threshold and an excess greater than the noise floor.
The configured minimum effect also applies to that excess.

G3 requires the standard runtime cases and both synthetic distributions.
It reports the worst ratio and significant regressions above 1.00.
G4 evaluates `dist/small` and the const timing component independently.
The const component applies only to copy.
Its no-call component is NA: `checked by binary test, P4`.
A copy timing pass therefore does not imply a complete G4 pass.

The goal implementation is `bench/fastmem_bench/goals.py`.
The goal tests are `bench/tests/test_v2.py`.
The thresholds come from G2 through G4 in `docs/fastmem-plan.md`.

### Build and libc-probe

The option `-Drev=<string>` sets the revision label. Its default is `unknown`.
Benchmarks always link libc and include compiler-rt.
The option `-Dlink-libc` remains accepted for command compatibility.
The library module and kernels remain unchanged.

The install step includes `bench-fastmem` and `libc-probe` for the selected target and CPU.
The bench step runs the measurement binary locally.
The test step includes startup resolution, calibration, order balance, and PMU reset tests.

The probe prints its libc path, glibc version, and resolved memory symbols as one JSON object.
Each symbol contains its address, optional symbol name, and actual pointer offset from the library base.
The symbol set includes `memcpy`, `memmove`, and `memset`.
Probe addresses and offsets remain hexadecimal strings for compatibility.

Each raw file must agree with the independent probe on all three glibc offsets and the libc path.
Process addresses are not compared because ASLR can change them.
A mismatch fails that target immediately, including during offline analysis.
The manifest retains the probe evidence.

The harness saves on-box disassembly for all three glibc functions beside the target artifacts.
These artifacts remain under gitignored result directories.
They never enter this MIT repository.
The clean-room rule is in `docs/fastmem-plan.md`.
