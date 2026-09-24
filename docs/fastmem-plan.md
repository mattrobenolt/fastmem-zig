# fastmem plan

## Mission

Make Zig memory operations fast. Zig code that uses `@memcpy`, `@memmove`,
or `@memset` with a runtime length calls compiler-rt, which is slower than
glibc. fastmem gives Zig a `memcpy`, `memmove`, and `memset` that are equal
to or faster than glibc on every benchmark target.

fastmem has two layers:

1. An explicit module: `fastmem.copy`, `fastmem.move`, `fastmem.set`. The
   caller opts in at each call site.
2. An opt-in symbol export: `fastmem.exportSymbols()`. With it, the
   `memcpy`, `memmove`, and `memset` symbols of the program are fastmem,
   so that ordinary builtins use fastmem too.

glibc is the reference that we measure against. fastmem does not use
glibc at run time and does not depend on libc.

## Why "faster than glibc" is possible

A glibc call from Zig goes through the PLT to an ifunc-selected function.
The call site gives glibc no information about size or alignment. fastmem
code is in the same compilation unit as the caller. When the size is
comptime-known or small, fastmem inlines straight-line vector code and
makes no call. That is the advantage. For large runtime sizes, glibc is a
strong kernel, and parity is the goal.

## Facts that the plan uses

- Zig 0.16 compiler-rt exports `memcpy` and `memmove` unconditionally, weak
  and hidden (`lib/compiler_rt.zig`, `lib/compiler_rt/memcpy.zig`). If the
  link pulls compiler-rt for any symbol (for example `__udivti3`, which
  `std.Io` timestamp math needs through `i96`), `@memcpy` binds to
  compiler-rt, also with `-lc`. Only a program that needs nothing from
  compiler-rt calls glibc through the PLT.
- A strong `memcpy` export in the program wins over compiler-rt and glibc.
  In ReleaseFast, every `@memcpy` call binds to it. In Debug, the
  self-hosted backends inline `@memcpy` and do not call the symbol.
- LLVM can turn the loop in a `memcpy` implementation into a call to
  `memcpy`: that is infinite recursion. The fastmem module must build with
  `no_builtin = true`. With `-fno-builtin` on the calling module, `@memcpy`
  becomes an inline byte loop, so the consumer module must not use it.
- A default-visibility export can go to `.dynsym` and interpose shared
  libraries. The x86_64 Debug backend exported it even with hidden
  visibility.
- glibc selections and thresholds for each target:
  `docs/research/hosts/README.md`.

## Licensing and the clean-room rule

fastmem is MIT (`LICENSE`).

- glibc is LGPL. Read its source or disassembly only to learn behavior:
  size classes, thresholds, instruction choices, loop structure. Do not
  copy, transcribe, or translate its code, in source or in disassembly.
  Do not commit glibc code or disassembly to this repository. Local copies
  live in `.bench-cache/glibc/` (gitignored).
- Arm Optimized Routines (MIT OR Apache-2.0 WITH LLVM-exception) and
  llvm-libc (Apache-2.0 WITH LLVM-exception) are permitted sources. A port
  keeps the upstream copyright notice in the file header and names the
  upstream file and commit. `THIRD_PARTY.md` lists every port.
- Compiler-rt (MIT, the Zig project) is a permitted source.
- Other code needs a license check before use.

## Goal: acceptance criteria

fastmem is done when all of these are true on all seven targets (c7i,
c8i, c7a, c8a, c7g, c8g, c9g), built with the `-Dcpu` of `bench.toml`.
Every number comes from the harness, with at least 5 rounds and the A/A
noise floor.

G1. Correctness.
- Guard-page tests pass for every operation: all sizes 0 to 1024, every
  source and destination offset 0 to 63, both overlap directions and every
  gap 1 to 128 for `move`, and sizes up to 1 MiB at page boundaries.
- The differential fuzzer against a byte-loop reference passes.
- The tests run on the target hardware of each box, not only locally.

G2. Kernel parity with glibc (C-ABI call, runtime length).
- Geometric mean of `fastmem_abi / glibc` over the standard suite is 1.00
  or less for each target and operation.
- No size tier has a geometric mean above 1.05.
- No single case is significantly slower than 1.10.

G3. Never slower than compiler-rt. No case of `fastmem_abi / builtin` is
significantly above 1.00.

G4. The inline advantage.
- On the small-size distribution (`dist/small`), `fastmem_inline / glibc`
  is 0.90 or less on every target.
- For comptime-known sizes up to 256 bytes, `fastmem.copy` generates no
  call and is not slower than `@memcpy` with the same comptime size.

G5. The export layer.
- With `fastmem.exportSymbols()`, ReleaseFast `@memcpy`, `@memmove`, and
  `@memset` calls bind to fastmem. A binary test proves it.
- The exported functions contain no branch to their own entry, and they
  do not appear in `.dynsym`. Binary tests prove it.
- The Zig standard library tests and one real project (handoff) pass
  with the export layer active.

G6. Portable builds. A baseline build (`-Dcpu=x86_64_v3` and
`-Dcpu=generic` on aarch64) is not slower than compiler-rt.

## Design decisions

- `memmove` is the primary kernel. `memcpy` is a fast path of it, as in
  glibc and Arm Optimized Routines.
- Kernel selection is comptime, from the build target CPU features. Runtime
  dispatch (cpuid once, a function pointer) is a later, opt-in addition.
- Kernels are organized by size class. The small classes use overlapping
  head and tail loads with branches. Mid sizes use a vector loop. Large
  sizes use `rep movsb` / `rep stosb` (x86, where the CPU and the
  thresholds allow it), an aligned SVE or NEON loop (aarch64), and
  non-temporal stores above a threshold.
- The current kernels in `src/` are reference material only. The new
  kernels start from the design memos. `src/root.zig` keeps the public
  API names.
- fastmem does not call `memcpy`, `memmove`, or `memset` through a symbol.
  With the export layer, such a call is recursion.

## Measurement

The measurement binary compares four implementations for each operation:

| impl | What it is |
|---|---|
| `builtin` | `@memcpy` / `@memmove` / `@memset` with a runtime length: compiler-rt, what Zig programs get today |
| `glibc` | the glibc function, resolved with `dlopen("libc.so.6")` and `dlsym`, called through the pointer |
| `fastmem_abi` | the fastmem kernel, called through a C-ABI function pointer (the G2 comparison) |
| `fastmem_inline` | `fastmem.copy` / `move` / `set` inlined in the timed loop (the G4 comparison) |

The binary proves the glibc resolution: the `dladdr` library path must be
the libc of the box. Otherwise the binary refuses to run. The contract is
in `docs/bench-design.md`.

## Phases

| Phase | Work | Owner | Exit |
|---|---|---|---|
| P0 | Ground truth: glibc variants and thresholds per target | parent | done: `docs/research/hosts/` |
| P1a | Measurement binary v2 (four impls, memset, verified glibc, fixed perf counters, calibration) and harness schema v2 | GPT-6 Astra (writer), Opus review | a 7-target baseline run |
| P1b | x86_64 design memo | Opus 5.5 (research) | reviewed memo |
| P1c | aarch64 design memo | Kimi K3 (research) | reviewed memo |
| P1d | Baseline: compiler-rt vs glibc on 7 targets | parent | `docs/results/baseline-0.16.md` |
| P1e | Size distributions of real Zig programs (uprobe on compiler-rt memcpy) | parent | `dist/zig-*` suites |
| P2 | Correctness framework: guard-page tests, fuzz, `bench test` runs test binaries on every box | Astra | G1 harness |
| P3 | memmove/memcpy kernels: aarch64 (K3 writes, Opus reviews), x86_64 (Astra writes, Opus reviews). Iterate with the harness against G2/G3 | lanes, parent gates | G1-G3 for copy and move |
| P4 | Inline layer | Opus design, K3 or Astra writes | G4 |
| P5 | memset, same method | lanes | G1-G4 for set |
| P6 | Export layer and ecosystem validation | Astra writes, Opus reviews | G5 |
| P7 | Portable builds, runtime dispatch (optional) | lanes | G6 |

## Working rules for lanes

- A lane never accepts its own work. The parent accepts with harness
  numbers. A reviewer from a different model family reviews each change.
- Every performance claim names its run directory under `bench-results/`.
- A change that helps one target and hurts another is rejected, unless a
  comptime per-target selection removes the harm. `asm-all` must show that
  the other targets do not change.
- A research memo cites a source for every factual claim: a file and line,
  a disassembly address in `.bench-cache/glibc/`, or a URL. A claim
  without a source is marked "unverified".
