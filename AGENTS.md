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
- `infra/` — OpenTofu stack (AWS `c7i`/`c7a`/`c8g` + OrbStack `orb-arm64`,
  NixOS images) and `bench.nu`, the nushell driver for sync/run/compare.

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
- `just bench-up` / `bench-run` / `bench-run-tagged <tag>` /
  `bench-compare <baseline> <candidate>` — the remote benchmark fleet.

## Benchmark targets

- `orb-arm64` — OrbStack NixOS VM on Apple Silicon; Linux/aarch64 sanity.
- `c7i` — AWS `c7i.large`, Intel Sapphire Rapids.
- `c7a` — AWS `c7a.large`, AMD Genoa. Materially noisier than the others;
  treat small deltas there with suspicion.
- `c8g` — AWS `c8g.large`, Graviton4 / Neoverse-V2.

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
