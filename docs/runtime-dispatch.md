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
- The object exports `fastmem_x86_<id>_<level>_memmove`, `_memset`, and `_name`.
- All three symbols have hidden visibility. They never reach `.dynsym`.
- The fastmem module receives the six objects through `Module.addObject`.
- The level objects get the `fastmem_options` of the public module.
  Thus `tuning.zig` applies the same per-model variant and experiment selection as in a comptime build for that CPU.

### Symbol names

`<id>` is a 16-digit hex id of the package instance (`instanceId` in `build.zig`).
Zig creates one `std.Build` for each pair of build root and user options.
The id hashes the same pair.
A fetched package uses its build root relative to the global cache, so its id does not depend on the cache location.
The resolvers and the generic entries also carry the id: `fastmem_x86_<id>_resolve_memcpy`, `fastmem_x86_<id>_generic_memcpy`.

Hidden visibility does not prevent collisions inside one link.
Two fastmem package copies in one executable therefore need different names.
The id also makes the generated `fastmem_options` files of two copies differ.
Without that, two identical options files share one cache path, and Zig rejects the compilation: "file exists in modules 'fastmem_options' and 'fastmem_options0'".

`Module.addObject` propagates in Zig 0.16.
`std.Build.Step.Compile` collects the link objects of every module in its module graph.
Thus an executable that imports `b.dependency("fastmem", ...).module("fastmem")` links the objects.
An object artifact (`zig build-obj`) merges them into its relocatable output.
A static library adds them as archive members.
A compiled consumer package proved the dependency path (see "Local evidence").

`Fastmem.configure` in `build.zig` applies the rule to every module of `src/root.zig`.
It sets the `fastmem_options` flags `x86_dispatch` and `x86_test_hooks`, and the `x86_instance` id.
`src/x86_64/dispatch.zig` applies the same rule at comptime, with that flag as the last condition.
Thus a module without the objects never references their symbols.

## Entry points

`src/x86_64/dispatch.zig` holds one function pointer for each operation: copy, move, and set.
Each pointer starts at a resolver function, as a lazy PLT entry does.

1. The first call through any pointer reads CPUID and XCR0. Only a size above 128 bytes reaches a pointer.
2. The resolver selects the level and stores all three pointers.
3. The resolver tail-calls the kernel of the selected level.

Every later call loads the pointer and makes one indirect jump.
There is no global constructor.
Two threads can resolve at the same time.
They store the same values, so the race is benign.
The loads and stores are monotonic atomics, which make the race defined.

`exportSymbols()` exports the C-ABI entries `abi.memcpy`, `abi.memmove`, and `abi.memset` as `memcpy`, `memmove`, and `memset`.
Each entry handles 0 to 128 bytes itself and never reads a pointer for these sizes.
The small classes compile in the fastmem module for the consumer CPU: SSE2 on baseline.
Thus they are the same code for every level.

| Size | Class | Instructions to `ret` (copy / set) |
|---|---|---|
| 0 | immediate return | 4 / 4 |
| 1 to 3 | three bytes (`compact.bytes`) | 14 / 11 |
| 4 to 15 | four 4-byte moves (`compact.quad`) | 23 / 22 |
| 16 to 63 | four 16-byte moves (`compact.quad`) | 25 / 27 |
| 64 to 128 | eight 16-byte moves | 28 / 24 |

Copy and move share the classes: every class loads all its bytes before its first store.
The entry tests zero first, then 1 to 3 bytes, then the 128-byte limit.
The large path costs eight instructions:

```text
testq  %rdx, %rdx
je     empty
cmpq   $4, %rdx
jb     bytes
cmpq   $0x80, %rdx
jbe    small
movq   copy_fn(%rip), %rax
jmpq   *%rax
```

The first fleet version jumped through the pointer at every size.
The G6 run 20260925T184717Z-p7-dispatch-g6 measured that at 0 to 16 bytes: copy against glibc went from 0.91 to 1.34 on c7i and from 0.85 to 1.53 on c8i.
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
`dispatch.zig` exports the resolvers and the generic entries with hidden `fastmem_x86_<id>_*` names for this purpose.
The audit found one real recursion during development.
In a Debug build without module `no_builtin`, `Info.select` called `memcpy` for a struct copy.

## Inline layer

A dispatch build cannot inline AVX2 code into baseline code.
Thus `fastmem.copy`, `move`, and `set` use the x86 inline ladder (`move.small`, `set.small`) up to 128 bytes.
128 bytes is the inline limit of the `x86_64_v3` comptime build.
The ladder compiles for the consumer CPU: SSE2 on baseline.
Larger sizes call through the pointer directly, without the stub.
A comptime size of 128 bytes or less makes no call.

## Introspection and test hooks

- `fastmem.dispatch.level()` returns the selected level, or null without dispatch.
- `fastmem.dispatch.kernelName()` returns the kernel name of the level.
- `fastmem.dispatch.detect()` returns the CPUID facts.
- `fastmem.dispatch.force(level)` selects a level. The CPU must support it.
- `fastmem-tests --x86-level LEVEL` runs the guard suite at one level.

`force` is a test hook. It compiles only when `fastmem_options.x86_test_hooks` is true.
Only fastmem's own test modules set it: the unit tests, the `test-dispatch` unit tests, and `fastmem-tests`.
`fastmem-tests` gets a private copy of the public module with the hooks. Its kernels are the same.
The public module never sets the flag.
A consumer that calls `force` gets this compile error:

```text
error: fastmem.dispatch.force is a test hook; the public fastmem module does not provide it
```

## Tests

`zig build test` includes `zig build test-dispatch`.
That step does these checks:

1. `src/x86_64/check_dispatch.py` inspects the baseline codegen probe.
   It follows each C-ABI entry with every size from 0 to 33 and the class edges up to 128.
   Each such path must return without a pointer read, a symbol reference, an indirect branch, or an AVX instruction.
   Sizes 129, 4096, and 64 MiB must end in the indirect jump through the pointer of the operation.
   It checks that fixed sizes 1 to 128 make no call and that 129 to 256 use the pointer.
   It checks that every `fastmem_x86_*` symbol is GLOBAL HIDDEN.
2. The same script compares each level object with the comptime codegen probe of the same CPU.
   The kernel functions and every function that they branch to must be instruction-identical.
   A negative check proves that two different levels differ.
   A table of the REP and NT use of each level, stated independently of `tuning.zig`, must match the large paths.
   No level uses REP for a forward overlap: `rep_fwd_gap_min` is null in every row.
3. `src/x86_64/run_dispatch.py` runs the unit tests in ReleaseFast and Debug under seven qemu CPU models.
   The unit tests force every level that the CPU supports.
4. The same script runs `dispatch-probe` under the seven models and checks the selected level.
5. A resolver-trap build (`x86_resolver_trap`, `src/x86_64/dispatch_small.zig`) executes `ud2` in every resolver.
   Under qemu `max` and `Westmere`, it copies, moves, and fills 0 to 128 bytes at three offsets through the C-ABI entries and the inline layer, and both overlap directions through `memmove`.
   Then it prints "small ok", and its first 129-byte call must die with SIGILL.
   The fixture does not call `exportSymbols()`: before `main`, the Zig start code zeroes the TLS area with a memset above 128 bytes, which traps.
   The exported symbols have the addresses of the C-ABI entries (`src/export/check.py`).
6. The unit tests move 12 MiB + 4 KiB with a 4113-byte gap in both directions at every supported level.
   The size is above the AMD NT threshold and the Intel REP threshold.

The export matrix adds an `x86_64-dispatch` row: baseline x86_64 in every link mode.
The collision tests add a baseline x86_64 row.

`zig build test-export-packages` (part of `test-export`) checks the package boundary:

1. Two compile-fail fixtures call `force` through a public module: the public module of the build, and a ReleaseFast baseline x86_64 consumer. Both must fail with the test-hook error.
2. `src/export/two_packages.py` copies the package twice and builds `src/export/two_packages/`.
   The consumer depends on both copies by path. Copy a exports the memory symbols, and copy b serves explicit calls.
   The script checks that the link contains two instance ids with eight dispatch entries each, and it runs the executable.
`src/x86_64/cpuid.zig` tests the selection with synthetic CPUID values of the four fleet hosts and of other models.

## Harness

- A dispatching `bench-fastmem` records the `dispatch` meta object: level, kernel, vendor, family, and model.
  A comptime-selected build emits no `dispatch` field.
  Its meta code is the code of the build before P7, so that the `.text` of the target-CPU binaries does not change.
- The capability comes from the binary. A dispatching binary exports its resolvers, and the codegen evidence in `meta.codegen` names them.
  Analysis requires the `dispatch` object exactly when the evidence names a resolver.
  Analysis rejects a meta record without codegen evidence when a level is expected.
- `bench run --cpu baseline` records the expected level of each x86 target in `dispatch_levels`.
  The expected level is the `zig_cpu` of the target.
  Analysis rejects a raw file with a different level.
- The build step rejects a revision with runtime dispatch (its `build.zig` declares `x86-dispatch`) whose G6 x86 binary has no resolvers.
  A revision without the feature builds a binary without resolvers. No level applies to it, and the report says so.
- `report.md` prints the dispatch state of each variant.
- `bench test` fails the baseline variant when the guard summary names a different level.
- `bench.toml` keeps `baseline_cpu = "x86_64"` on the x86 targets.

## Large forward overlaps on c8a

The large run 20260925T194532Z-p7-dispatch-large measured `move/fwd-gap{1,15,17}/67108864` at 1.57 to 1.61 against compiler-rt on c8a.
`fwd-gap4096` was 1.39 and `fwd-half` was 1.26 at the same size.
The same rows at 16 MiB, and all rows on c7a, c7i, and c8i, are at or below 1.03.

The dispatch does not cause it:

- In the fleet binary, `rep movsb` occurs only in the `sapphirerapids` and `graniterapids` move kernels.
- The `znver5` level `move.largeKernel` has 232 instructions. They are identical to `x86_64.move.largeKernel` of a `-Dcpu=znver5` build of the same tree.
- `rep_fwd_gap_min` is null in every row of `tuning.zig`, and `rep_movsb_min` is null on AMD.
- A forward overlap takes the `forward` vector loop in both builds.

No large-suite run of a `-Dcpu=znver5` build exists. Thus the comptime kernel has the same unmeasured cost.
The fix belongs to the x86 kernel lane. "Fleet commands" gives the target-CPU run that confirms it.

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
- The tuning overrides (`-Dx86-vec` and others) apply to every level object.
  For example, `-Dx86-vec=64` fails the `x86_64_v3` object.
- The dispatch inline limit is fixed at 128 bytes. `-Dx86-inline-max` does not change it.
- qemu TCG does not execute AVX-512. The local runs execute only `generic` and `x86_64_v3`.
  The fleet runs execute the model levels.
- `force` accepts a model level on another model when the CPU has x86-64-v4.
  The kernel is then correct, but its thresholds belong to the other model.

## Local evidence, 2026-09-25

The host is launchpad (aarch64). qemu-x86_64 11.1.1 runs the x86 binaries.
The first table is the state after the review fixes, merged with main 8d43448 (`-Dx86-experiment=auto`).

| Check | Result |
|---|---|
| `zig build test test-dispatch test-export codegen-x86`, after the small-size fix | 348 of 348 steps, 36 of 36 unit tests |
| Resolver-trap build under qemu `max` and `Westmere` | 0 to 128 B pass, 129 B traps |
| Guard suite, baseline musl, after the small-size fix | `x86_64_v3` and `generic`: 28,047,836 cases each, pass |
| `zig build test` | 318 of 318 steps, 36 of 36 unit tests |
| `bench-fastmem` `.text`, main 8d43448 and P7, `-Drev=cmp` | identical for sapphirerapids, graniterapids, znver4, znver5, and x86_64_v3 |
| Codegen probe `.text`, main 8d43448 and P7 | identical for the same five CPUs |
| `test-export-packages` | both hook fixtures fail to compile; two instances link and run (`x86_64_v3` under qemu) |
| Harness | 232 passed, 11 skipped |

The earlier evidence, before the review fixes:

| Check | Result |
|---|---|
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
| `max` | `x86_64_v3`, detected | none, after the review fixes and the main merge | 28,047,836 | pass | 352 s |
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

2. Measure G6 with the dispatched kernels. The first revision is main before P7. Its baseline binary has no dispatch, and the report says so.

```sh
just bench-run --rev 8d43448 --rev WORKTREE --cpu baseline --target c7i --target c8i --target c7a --target c8a --suite standard --rounds 5 --label p7-dispatch-g6
```

3. Measure the large sizes, which reach the REP and NT paths.

```sh
just bench-run --rev WORKTREE --cpu baseline --target c7i --target c8i --target c7a --target c8a --suite large --rounds 5 --label p7-dispatch-large
```

4. Measure the c8a forward overlaps with the comptime `znver5` kernel (`--cpu target`, the default).
   Equal ratios confirm that the cost is in the kernel, not in the dispatch.

```sh
just bench-run --rev WORKTREE --target c8a --suite large --filter move/fwd --rounds 5 --label c8a-fwd-comptime
```

5. Read the results.

```sh
just b analyze <run-dir>
```

`report.md` prints the dispatch state of each variant.
The expected levels are `sapphirerapids` on c7i, `graniterapids` on c8i, `znver4` on c7a, and `znver5` on c8a.
