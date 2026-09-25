# fastmem-zig: agent notes

fastmem gives Zig a `memcpy`, `memmove`, and `memset` that are equal to or
faster than glibc and compiler-rt. `README.md` is the user overview.
`docs/fastmem-plan.md` is the plan: mission, goals G1-G6, the clean-room
rule, and the facts that the design depends on. Read it before you change
a kernel or make a performance claim.

## Layout

- `src/root.zig`: the public API. `copy`, `move`, `set` (inline),
  `abi.memcpy/memmove/memset` (C-ABI kernel entries), `impl` (kernel names
  per op), and `exportSymbols()`. It selects a kernel per target.
- `src/x86_64/`: the x86_64 kernels (AVX-512 and AVX2). `tuning.zig` holds
  the per-model table and `-Dx86-variant=auto` resolution.
  `check_codegen.py` is the codegen gate. `README.md` describes the design.
- `src/aarch64/`: ports of Arm Optimized Routines (SVE and AdvSIMD) as
  global asm, plus `small.zig` (the inline small classes) and `tuning.zig`
  (the per-model small-path table).
- `src/memcpy.zig`, `memmove.zig`, `forward.zig`, `common.zig`: the generic
  Zig fallback for targets without a dedicated kernel (x86_64 without AVX2,
  other architectures).
- `src/export/`: `exportSymbols()` tests and binary checks, including the
  pinned aarch64 kernel bytes (`check_kernel_bytes.py`).
- `src/tests/`: the guard-page correctness suite (`fastmem-tests`), fuzzers,
  and the call paths (runtime, C-ABI, comptime size).
- `src/bench_fastmem.zig`: the measurement binary (JSONL schema v3).
  `src/libc_probe.zig`: the glibc resolution probe.
- `src/asm_probe.zig`: C-ABI wrappers for `zig build asm`.
- `bench/`: the Python (uv) harness. `ec2bench/` is the generic fleet
  library. `fastmem_bench/` builds, runs, and analyzes. `bench.toml`
  configures both.
- `infra/`: OpenTofu. `modules/bench-iam` and `modules/bench-base`, root
  stacks `iam/` (a human applies it) and `base/` (the agent applies it).
  `infra/README.md` is the runbook.
- `docs/`: `fastmem-plan.md`, `bench-design.md` (the benchmark contract),
  `export-layer.md`, `research/` (design memos, host facts), `results/`
  (one file per fleet measurement).

## Toolchain

- Zig 0.16.0 from the flake. Read `.pi/skills/zig/SKILL.md` before you
  write Zig here. 0.15-era patterns are wrong in 0.16 in silent ways
  (`std.Io`, `main(init)`, `testing.Smith`).
- The flake is the environment. Add a missing tool to `flake.nix`; do not
  install it globally.
- Fuzz mode hits ziglang/zig#30655 in Debug. `just fuzz` uses ReleaseSafe.

## Commands

- `just test`: unit tests, export checks, and a build of every shipped
  binary. It must pass before a commit.
- `just test-guard`: the guard-page matrix on this host.
- `just codegen-x86`: the x86 codegen gate for every fleet CPU model.
- `just bench-up [targets]`, `just bench-test --optimize ReleaseFast
  --optimize ReleaseSafe --optimize Debug`, `just bench-run --rev A --rev B
  --suite standard --rounds 5`, `just b analyze <run-dir>`, `just
  bench-down`. `bench run --cpu baseline` measures G6.
- `ziglint src/` before you call Zig work done.

## Benchmark targets

`bench.toml` is the source of truth. All `.xlarge`, us-west-2, account
396684171460 ("playground"), profile `fastmem-bench`.

| Target | CPU | x86 variant / aarch64 small path |
|---|---|---|
| c7i | Sapphire Rapids | straight_1k |
| c8i | Granite Rapids | straight_1k |
| c7a | Zen 4 | tiered |
| c8a | Zen 5 | compact |
| c7g | Neoverse V1 (256-bit SVE) | copy/set sve, move hybrid |
| c8g | Neoverse V2 | copy/set sve, move hybrid |
| c9g | Neoverse V3 | copy/set neon, move hybrid |

## Rules

- Clean room: glibc is LGPL. Read it only to learn behavior. Never copy,
  transcribe, or translate its code, in source or disassembly. glibc
  binaries and disassembly stay in `.bench-cache/glibc/` (gitignored).
  Ports come from Arm Optimized Routines or llvm-libc, with attribution in
  `THIRD_PARTY.md`.
- fastmem never calls `memcpy`, `memmove`, or `memset` through a symbol.
  The harness marks such a build INVALID. The fastmem module builds with
  `no_builtin` and `omit_frame_pointer`.
- The inline layer contains no loops. Loops go in non-inline functions of
  the `no_builtin` module.
- A performance claim names its run directory and a results file in
  `docs/results/`. A change that helps one target and hurts another needs a
  comptime per-model selection.
- A kernel change that changes aarch64 bytes updates GOLDEN in
  `src/export/check_kernel_bytes.py` in the same commit, on purpose.
- Fleet scripts tear down only the targets that they launched. `bench down
  --all` stops every run on the fleet.

## Git

- Never `git add -A` or `git add .`. Stage tracked changes with `git add -u`,
  and add a new file by its path after you read `git status --short`.
  Untracked files can hold secrets: qemu-user core dumps (`*.core`) contain
  the whole process environment.
