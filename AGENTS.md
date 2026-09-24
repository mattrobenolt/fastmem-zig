# fastmem-zig

SIMD-optimized `memcpy`/`memmove` in Zig. Goal: match or beat platform libc.

## Layout

- `src/root.zig` — public facade: `fastmem.copy` / `fastmem.move`, the `flags`
  snapshot (`CopyFlags` / `MoveFlags`), inline wrappers, tests + fuzzers.
- `src/common.zig` — shared SIMD load/store primitives, `chunk_bytes`/`stride`.
- `src/forward.zig` — overlap-safe forward kernel.
- `src/memcpy.zig`, `src/memmove.zig` — copy/move policy decisions and Flags.
- `src/bench_fastmem.zig` — benchmark harness: builtin vs fastmem vs optional
  libc; 9 samples per case with p50/p95; warmup 20 ms, samples 60 ms;
  benchstat-compatible output lines.
- `src/asm_probe.zig` — C-ABI exports (`fastmem_copy` etc.) for asm inspection.
- `src/libc_probe.zig` — `dlsym` probe reporting which libc symbols a build
  actually resolves to (JSON on stdout).
- `build.zig` — `test`, `bench` (always ReleaseFast), `libc-probe`,
  `asm` / `asm-all` (5 cross targets).
- `docs/benchmark-hosts.md` — per-target benchmark evidence and learnings.
  Read it before making or repeating performance claims.
- `docs/bench-design.md` — the benchmark system contract (infra, harness,
  JSONL schema, statistics). `infra/README.md` is the fleet runbook.
- `infra/` — OpenTofu: `modules/bench-iam` + `modules/bench-base`
  (copyable pattern), root stacks `iam/` (human applies) and `base/`
  (agent applies), NixOS boxes with a TTL guard and a reaper Lambda.
- `bench/` — Python (uv) harness: `ec2bench/` (generic fleet library,
  copyable) and `fastmem_bench/` (build, run protocol, analysis).
  `bench.toml` configures both.

## Toolchain

- Zig 0.16.0 via the flake (`zig_0_16`); `minimum_zig_version` is 0.16.0.
  Ported from 0.15.2 on 2026-09-23.
- Read `.pi/skills/zig/SKILL.md` before writing Zig here. It is verified
  against this toolchain; 0.15-era patterns from training data are wrong
  in specific, silent ways (`std.Io`, `main(init)`, `testing.Smith`).
- Fuzz mode hits an upstream 0.16.0 bug (ziglang/zig#30655, self-hosted
  backend, Debug only). `just fuzz` passes `-Doptimize=ReleaseSafe` to force
  the LLVM backend around it.

## Commands

- `just test` — full test suite.
- `just fuzz` — fuzzer (iteration budget with K/M/G suffix).
- `just bench` / `just bench-libc` — local benchmark runs.
- `just asm` / `just asm-all` / `just show-fn <fn>` — codegen inspection.
- `just bench-up [targets]` / `bench-ls` / `bench-down` — the fleet
  (profile `fastmem-bench`; boxes self-destruct, the reaper backstops).
- `just bench-run --rev A --rev B --suite quick` — build locally, measure
  on every running box in parallel, write `bench-results/<run-id>/`.
- `just b analyze <run-dir>` — re-analyze saved raw rounds offline.
- `just b <cmd>` — any harness command; `just bench-check` — harness tests.

## Benchmark targets

`bench.toml` is the source of truth (instance type, Zig target, `-Dcpu`).
All `.xlarge`, us-west-2, account 396684171460 ("playground").

- `c7i` — Intel Sapphire Rapids (SMT 2/core).
- `c8i` — Intel Granite Rapids (SMT 2/core).
- `c7a` — AMD Genoa (1 thread/core). Materially noisier in 0.15-era runs.
- `c8a` — AMD Turin (1 thread/core).
- `c7g` — Graviton3 / Neoverse-V1 (256-bit SVE).
- `c8g` — Graviton4 / Neoverse-V2 (128-bit SVE).
- `c9g` — Graviton5 (`-Dcpu=neoverse_v3` unverified).

## Performance state

All recorded evidence in `docs/benchmark-hosts.md` is from the 0.15.2
toolchain. Nothing has been benchmarked on 0.16 yet.

- x86 with ERMS/FSRM: `rep movsb` (the builtin) is the floor for large
  aligned copies — delegate rather than fight it.
- c8g: aligning the hot loop around source loads (matching glibc's
  `__memcpy_sve` / `__memmove_sve`) fixed the worst regressions. Remaining
  gaps: large aligned 4096/16384 B copy, some 256 B cross-lane rows, and
  narrow backward-overlap rows near 256 B.
- A single-stride exact fast path fixed small-copy (64 B) regressions on
  c8g. The broader `2 * stride` variant helped c8g but hurt Intel badly
  enough to drop — keep only the single-stride version.
- glibc-floor delegation thresholds for libc-linked builds live in the
  Flags structs in `src/memcpy.zig` / `src/memmove.zig`.

## Zig notes

- File-scope `const` is already comptime — no redundant `comptime` keyword.
- `std.Target.Cpu.Model` is a struct; compare by pointer:
  `builtin.cpu.model == &std.Target.aarch64.cpu.generic`.
- Vector width: `std.simd.suggestVectorLength(u8)` — 16 on NEON, 32 on AVX2.
- Run `ziglint src/` before calling work done; pre-existing warnings in
  `bench_fastmem.zig` long lines are known and tolerated.
