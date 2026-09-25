# Runtime CPU dispatch on x86_64 (P7)

An x86_64 build without AVX2 selects its kernels at run time.
One binary for `-Dcpu=baseline` then runs the AVX-512 kernels on AVX-512 hosts and the AVX2 kernels on AVX2 hosts.
Other hosts run the generic kernels.
This document gives the design, the tests, the limits, and the fleet commands.
GitHub issue #1 gives the motivation: handoff ships x86_64 with `-Dcpu=baseline`.

## Scope

Dispatch is active when all of these conditions are true:

- The target is x86_64 Linux with the ELF object format.
- The target CPU does not have AVX2. Examples are `baseline`, `x86_64`, and `x86_64_v2`.
- The build option `-Dx86-dispatch` is true. This is the default.

Every other build keeps the comptime kernel selection of `src/root.zig`.
An AVX2 or AVX-512 `-Dcpu` build contains no dispatch code.
Its codegen probe `.text` is byte-identical to the build before P7 (see "Local evidence").

A consumer disables dispatch with the dependency option:

```zig
const fastmem = b.dependency("fastmem", .{ .target = target, .@"x86-dispatch" = false });
```

## Levels

A level is the `-Dcpu` of one kernel object.
The object of a level contains the kernels of a comptime build for that CPU.

| Level | Required features | Selected on | Tuning row of `src/x86_64/tuning.zig` |
|---|---|---|---|
| `generic` | none | hosts without the full x86-64-v3 set | the generic Zig kernels, compiled for the consumer CPU |
| `x86_64_v3` | x86-64-v3 | AVX2 hosts. Also Skylake-SP, Cascade Lake, Cooper Lake, and Ice Lake. | 32-byte vectors, no REP, no NT |
| `x86_64_v4` | x86-64-v4 | AVX-512 hosts of other models | 64-byte vectors, no REP, no NT |
| `sapphirerapids` | x86-64-v4 | Intel family 6, model 0x8f (c7i) | REP and NT thresholds of c7i |
| `graniterapids` | x86-64-v4 | Intel family 6, model 0xad (c8i) | REP and NT thresholds of c8i |
| `znver4` | x86-64-v4 | AMD family 0x19, Zen 4 model ranges (c7a) | NT threshold, `tiered` |
| `znver5` | x86-64-v4 | AMD family 0x1a (c8a) | NT threshold, `compact` |

The x86-64-v3 check reads these features:

- CPUID.1:ECX: SSE3, SSSE3, FMA, CX16, SSE4.1, SSE4.2, MOVBE, POPCNT, XSAVE, OSXSAVE, AVX, F16C.
- CPUID.7.0:EBX: BMI1, AVX2, BMI2.
- CPUID.80000001H:ECX: LAHF/SAHF, LZCNT.
- XCR0: the SSE and AVX state bits.

The x86-64-v4 check adds AVX512F, AVX512DQ, AVX512CD, AVX512BW, and AVX512VL.
It also adds the opmask, ZMM_Hi256, and Hi16_ZMM bits of XCR0.
The dispatcher executes XGETBV only when OSXSAVE is set.
A model level also requires the full x86-64-v4 set.
Thus a hypervisor that masks AVX-512 on a Sapphire Rapids host gets `x86_64_v3`.

### Why the dispatcher reads the model

The per-model rows contain the only knobs that can make a kernel slower than the untuned row: REP thresholds and NT thresholds.
The fleet measured each row on its own model (`docs/results/p3-x86c.md`, `docs/results/p3-x86d.md`).
A dispatched host therefore runs the same kernel as a `-Dcpu=<model>` build.
An unknown AVX-512 model gets `x86_64_v4`, which has no REP and no NT stores.
That row cannot select REP on AMD, and it cannot start NT stores below the cache size.
This is the most conservative table.
The model numbers mirror the Zig 0.16 host detection (`lib/std/zig/system/x86.zig`, MIT).
`src/x86_64/cpuid.zig` contains the table and the synthetic-CPUID tests.

The dispatcher does not read the CPUID stepping.
Thus Cooper Lake (model 0x55) gets the 32-byte row, but a comptime `cooperlake` build gets 64-byte vectors.
The NT thresholds describe the fleet instance sizes, as in the comptime builds.

## Build structure

Zig 0.16 has no per-function target features (`docs/fastmem-plan.md`, Facts).
One compilation cannot contain baseline code and AVX2 code.
Thus `build.zig` compiles each level as a separate object.

- The root of each object is `src/x86_64/level.zig`.
- The object compiles with `-Dcpu=<level>`, ReleaseFast, LLVM, PIC, `no_builtin`, and `omit_frame_pointer`.
- The object exports `fastmem_x86_<level>_memmove`, `fastmem_x86_<level>_memset`, and `fastmem_x86_<level>_name`.
- All three symbols have hidden visibility. They never reach `.dynsym`.
- The fastmem module receives the six objects through `Module.addObject`.

`Module.addObject` propagates in Zig 0.16.
`std.Build.Step.Compile` collects the link objects of every module in its module graph.
Thus an executable that imports `b.dependency("fastmem", ...).module("fastmem")` links the objects.
An object artifact (`zig build-obj`) merges them into its relocatable output.
A static library adds them as archive members.
A compiled consumer package proved the dependency path (see "Local evidence").

`Fastmem.configure` in `build.zig` applies the rule to every module of `src/root.zig`.
It sets the `fastmem_options` flag `x86_dispatch`.
`src/x86_64/dispatch.zig` applies the same rule at comptime, with that flag as the last condition.
Thus a module without the objects never references their symbols.

## Entry points

`src/x86_64/dispatch.zig` holds one function pointer for each operation: copy, move, and set.
Each pointer starts at a resolver function, as a lazy PLT entry does.

1. The first call through any pointer reads CPUID and XCR0.
2. The resolver selects the level and stores all three pointers.
3. The resolver tail-calls the kernel of the selected level.

Every later call loads the pointer and makes one indirect jump.
There is no global constructor.
Two threads can resolve at the same time.
They store the same values, so the race is benign.
The loads and stores are monotonic atomics, which make the race defined.

The C-ABI entries `abi.memcpy`, `abi.memmove`, and `abi.memset` are the stubs.
`exportSymbols()` exports the stubs as `memcpy`, `memmove`, and `memset`.
Each stub is two instructions:

```text
movq   copy_fn(%rip), %rax
jmpq   *%rax
```

A glibc PLT entry is one instruction (`jmp *GOT(%rip)`).
LLVM 21 does not fold the load into the jump (see "Zig 0.16 limitations").

The x86 `memcpy` is the memmove kernel, as in the comptime builds.
At the `generic` level, `memcpy` uses the forward-only generic copy.

### Recursion

The resolver runs inside the first memory call of the process.
It must not call `memcpy`, `memmove`, or `memset`, because the pointer still points to the resolver.
Every function on the resolver path uses `@disableIntrinsics()`, in addition to the module `no_builtin`.
The generic kernels call the generic implementations directly, not the public API.

The export audit (`src/export/check.py`) follows direct branches only.
The stubs jump through pointers, so the audit also starts at every `fastmem_x86_*` function.
`dispatch.zig` exports the resolvers and the generic entries with hidden `fastmem_x86_*` names for this purpose.
The audit found one real recursion during development.
In a Debug build without module `no_builtin`, `Info.select` called `memcpy` for a struct copy.

## Inline layer

A dispatch build cannot inline AVX2 code into baseline code.
Thus `fastmem.copy`, `move`, and `set` use the x86 inline ladder (`move.small`, `set.small`) up to 128 bytes.
128 bytes is the inline limit of the `x86_64_v3` comptime build.
The ladder compiles for the consumer CPU: SSE2 on baseline.
Larger sizes call through the pointer directly, without the stub.
A comptime size of 128 bytes or less makes no call.

## Test hooks

- `fastmem.dispatch.level()` returns the selected level, or null without dispatch.
- `fastmem.dispatch.kernelName()` returns the kernel name of the level.
- `fastmem.dispatch.detect()` returns the CPUID facts.
- `fastmem.dispatch.force(level)` selects a level. The CPU must support it.
- `fastmem-tests --x86-level LEVEL` runs the guard suite at one level.

## Tests

`zig build test` includes `zig build test-dispatch`.
That step does these checks:

1. `src/x86_64/check_dispatch.py` inspects the baseline codegen probe.
   It checks the two-instruction stubs and the pointer of each operation.
   It checks that fixed sizes 1 to 128 make no call and that 129 to 256 use the pointer.
   It checks that every `fastmem_x86_*` symbol is GLOBAL HIDDEN.
2. The same script compares each level object with the comptime codegen probe of the same CPU.
   The kernel functions and every function that they branch to must be instruction-identical.
   A negative check proves that two different levels differ.
3. `src/x86_64/run_dispatch.py` runs the unit tests in ReleaseFast and Debug under seven qemu CPU models.
   The unit tests force every level that the CPU supports.
4. The same script runs `dispatch-probe` under the seven models and checks the selected level.

The export matrix adds an `x86_64-dispatch` row: baseline x86_64 in every link mode.
The collision tests add a baseline x86_64 row.
`src/x86_64/cpuid.zig` tests the selection with synthetic CPUID values of the four fleet hosts and of other models.

## Harness

- `bench-fastmem` records the `dispatch` meta object: level, kernel, vendor, family, and model.
- `bench run --cpu baseline` records the expected level of each x86 target in `dispatch_levels`.
  The expected level is the `zig_cpu` of the target.
  Analysis rejects a raw file with a different level.
- `report.md` prints the dispatched level of each variant.
- `bench test` fails the baseline variant when the guard summary names a different level.
- `bench.toml` keeps `baseline_cpu = "x86_64"` on the x86 targets.

## Zig 0.16 limitations

Each item comes from a compiled experiment.

- No per-function target features. The design uses separate objects for each level.
- The self-hosted x86_64 backend (Debug) rejects `@call(.always_tail, ...)`.
  The error is "unable to perform tail call".
  The stubs and resolvers use a normal call in that backend.
- LLVM 21 does not fold the pointer load into `jmp *mem`.
  The result is the same for `.always_tail`, for a plain call, and for plain, monotonic, and unordered loads.
  `zig cc -O2 -fomit-frame-pointer` on the equivalent C code gives the same two instructions.
  A naked assembly stub can give one instruction. P7 does not use one: it adds an exported data symbol and a second code path for the self-hosted backend.
- `Module.addObject` adds an include directory for each object. The compile command repeats `-I` six times. This has no effect.

## Limits

- Only x86_64 Linux ELF targets dispatch. Other x86_64 targets keep the generic kernels.
- Two fastmem packages in one link export the same hidden symbols. The link fails with a duplicate-symbol error.
- The tuning overrides (`-Dx86-vec` and others) apply to every level object.
  For example, `-Dx86-vec=64` fails the `x86_64_v3` object.
- The dispatch inline limit is fixed at 128 bytes. `-Dx86-inline-max` does not change it.
- qemu TCG does not execute AVX-512. The local runs execute only `generic` and `x86_64_v3`.
  The fleet runs execute the model levels.
- `force` accepts a model level on another model when the CPU has x86-64-v4.
  The kernel is then correct, but its thresholds belong to the other model.

## Local evidence, 2026-09-25

The host is launchpad (aarch64). qemu-x86_64 11.1.1 runs the x86 binaries.

| Check | Result |
|---|---|
| `zig build test` | 312 of 312 steps, 35 of 35 unit tests |
| `check_dispatch.py` | stubs two instructions, 9 bytes each. Six level objects identical to the comptime kernels. |
| Codegen probe `.text`, before and after P7 | identical for sapphirerapids, graniterapids, znver4, znver5, and x86_64_v3 |
| aarch64 `asm-all` instructions, Linux | identical. macOS: only the `setFallback` symbol name differs. |
| `test-export-arm-bytes` | all four CPUs match GOLDEN |
| `dispatch-probe` under qemu `max`, `Haswell` | `x86_64_v3` |
| `dispatch-probe` under qemu `SapphireRapids`, `EPYC-Genoa` | `x86_64_v3`: model 143 and family 25 model 17, AVX-512 masked by TCG |
| `dispatch-probe` under qemu `Westmere`, `max,-bmi2`, `max,-movbe` | `generic` |
| Unit tests, ReleaseFast and Debug, seven qemu models | 31 of 31 each |
| Consumer package through `b.dependency`, `exportSymbols()`, x86_64-linux-musl baseline | correct for 0 to 5000 bytes. `x86_64_v3` under `max`, `generic` under `Westmere`. |

The guard-suite results are in "Guard suite under qemu".

## Guard suite under qemu

The binary is `fastmem-tests` for `-Dtarget=x86_64-linux-musl -Dcpu=x86_64`, ReleaseFast.
The musl target gives a static binary that qemu runs without an x86 sysroot.
The maximum size is 1 MiB, the default of a baseline build.

| qemu CPU | Level | Build options | Cases | Result | Time |
|---|---|---|---:|---|---:|
| `max` | `x86_64_v3`, detected | none | 28,047,836 | pass | 435 s |
| `max` | `generic`, `--x86-level generic` | none | 28,047,836 | pass | 432 s |
| `Westmere` | `generic`, detected | none | 28,047,836 | pass | 389 s |
| `max` | `x86_64_v3`, detected | `-Dx86-rep-movsb-min=512 -Dx86-rep-stosb-min=512 -Dx86-nt-min=4096 -Dx86-memset-nt-min=4096` | 28,047,836 | pass | 604 s |

The last row runs the REP and NT paths of the level object through the dispatch stubs.
It does not test AVX-512 instructions.

## Fleet commands

Run these commands from the parent checkout after the merge.
They do not launch boxes. Launch the four x86 targets first with `just bench-up c7i c8i c7a c8a`.

1. Run the correctness matrix. It tests the target and baseline builds on each box.

```sh
just bench-test --target c7i --target c8i --target c7a --target c8a --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
```

2. Measure G6 with the dispatched kernels. The first revision is the build before P7.

```sh
just bench-run --rev 11cd5ed --rev WORKTREE --cpu baseline --target c7i --target c8i --target c7a --target c8a --suite standard --rounds 5 --label p7-dispatch-g6
```

3. Measure the large sizes, which reach the REP and NT paths.

```sh
just bench-run --rev WORKTREE --cpu baseline --target c7i --target c8i --target c7a --target c8a --suite large --rounds 5 --label p7-dispatch-large
```

4. Read the results.

```sh
just b analyze <run-dir>
```

`report.md` prints the dispatched level of each variant.
The expected levels are `sapphirerapids` on c7i, `graniterapids` on c8i, `znver4` on c7a, and `znver5` on c8a.
