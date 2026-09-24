# Opt-in memory symbols

`fastmem.exportSymbols()` gives one ELF link unit strong, hidden definitions of three memory symbols:

- `memcpy`
- `memmove`
- `memset`

Each definition has the address of the corresponding `fastmem.abi` entry.
The export adds no wrapper or trampoline.
An import alone does not replace these symbols.

## Enable the exports

1. Add fastmem as a Zig package dependency.
2. Add its public module to the executable root module.

```zig
const fastmem = b.dependency("fastmem", .{ .target = target });
exe.root_module.addImport("fastmem", fastmem.module("fastmem"));
```

3. Add this line to the root source file.

```zig
comptime { @import("fastmem").exportSymbols(); }
```

4. Remove other strong definitions of the three memory symbols from the same link.
5. For Debug builds, set `exe.use_llvm = true` or pass `-fllvm` to `zig build-exe`.

## API choice

The root comptime call makes the executable owner responsible for the replacement.
A dependency import cannot enable it by accident.
The same API also works with `zig test` and shared libraries.

The package module sets `no_builtin = true` for the kernels.
The consumer module keeps its normal builtin behavior.
The consumer must not set `no_builtin = true` for this feature.
That setting can replace builtin calls with inline loops, which symbol exports cannot intercept.

Zig functions use `@export` with `.strong` linkage and `.hidden` visibility.
The aarch64 ABI entries are assembly functions.
Zig 0.16 rejects `@export` of an extern function.
The aarch64 path therefore uses strong, hidden ELF aliases through `.globl`, `.hidden`, and `.set`.

## Guarantees

For runtime byte lengths, the ReleaseFast and ReleaseSafe consumer probes call the fastmem ABI entries.
The probes cover links both with and without libc.
They also cover links both with and without the compiler-rt `__udivti3` helper.
The strong definitions take precedence over compiler-rt and glibc.

The exported kernel bodies contain no branch to any memory entry.
The binary tests also follow direct branches into Zig kernel helpers.
They exclude standard-library panic handlers for invalid inputs.
A ReleaseSafe panic handler can use memory functions for its diagnostic output.
The checks do not claim a proof for arbitrary indirect control flow.

The three symbols do not appear in `.dynsym`.
This holds for the executable probes and the shared-library probes.
LLD can convert hidden global symbols to local symbols in the final image.
The relocatable-object tests check that each original definition is `GLOBAL HIDDEN`, not `WEAK`.

## Scope and limits

The API accepts aarch64 and x86_64 ELF targets with the LLVM backend.
The binary suite tests Linux with Zig 0.16.0.
Other object formats and non-LLVM backends receive a compile error.

The target CPU selects the kernel at compile time.
The export does not add runtime CPU dispatch.
The executable must run on a CPU that supports its target features.

Small or constant-size builtins can remain inline.
The export only replaces operations that become symbol calls.
It does not force every builtin through a function.

### Debug

The API refuses non-LLVM backends because their symbol visibility is not part of this guarantee.
Debug with LLVM passes the linked binary checks and the runtime consumer tests on both architectures.

The separate `-fno-llvm` Debug probes establish this actual Zig 0.16 behavior for runtime byte lengths:

| Backend | `@memcpy` | `@memmove` | `@memset` |
|---|---|---|---|
| x86_64 | Symbol call | Symbol call | Inline `rep stosb` |
| aarch64 | Symbol call | Symbol call | Symbol call |

These results replace the earlier assumption that every Debug memory builtin stays inline.
The probes retain runtime safety checks and use a trap-only panic handler.

### Shared libraries

A shared library can opt in for its own link unit.
Its internal calls bind to its hidden fastmem definitions.
Those definitions do not interpose the executable or other shared libraries.
The tests inspect both direct calls and `.dynsym` in `-dynamic` library builds.

An executable export does not replace the private memory operations of an already-built shared library.
For example, handoff's AWS-LC shared library keeps its own glibc calls.

### C objects

C objects in the same link bind their ordinary memory calls to fastmem too.
This behavior is intentional: the opt-in covers the link unit, not only Zig source files.
A C compiler can still inline an operation.
The C fixture uses `addCSourceFile` with `-fno-builtin` so its calls remain visible in the binary test.

The export layer does not define fortified aliases such as `__memcpy_chk`.
The Zig builtin probes do not call those aliases.
Compiler-rt can still supply unused fortified definitions, notably in Debug builds.
Fortified C calls keep their existing bounds-check behavior.

### Competing definitions

The link must have only one strong provider of each memory symbol.
An existing replacement must be removed before this API is enabled.

A conflicting Zig export in the same assembly unit can silently replace an aarch64 `.set` alias.
The compiler does not always report a duplicate symbol in that case.
The handoff validation caught this conflict through ABI-address checks before its final test runs.

## Test commands

Run the binary matrix through the flake:

```sh
nix develop -c zig build test-export
```

Run the upstream standard-library subset:

```sh
nix develop -c zig build test-export-std
```

`zig build test` also runs `test-export`.
The standard-library subset is a separate step because its four builds take several minutes.
The Linux test environment needs Python and LLVM tools from the flake.
Cross-architecture execution uses user-mode QEMU from the flake.

The binary matrix covers these cases:

- Both architectures, both release modes, libc on or off, and u128 division on or off.
- Debug with LLVM, Debug builtin probes without LLVM, and refusal of non-LLVM exports.
- Opt-out controls, relocatable-object linkage, dynamic executables, and shared libraries.
- Generic aarch64, Neoverse V1/V2/V3, x86_64 baseline, and x86_64_v3.

The libc-free consumer tests execute every length from 0 through 8192 bytes.
They check copy, fill, and both move directions against byte-level expectations.
They also execute the C calls.
Cross-built glibc executables and shared libraries receive binary inspection, not execution.
The SVE-specific matrix entries receive binary inspection.
The native standard-library and handoff tests exercise SVE on launchpad.

## Ecosystem validation

The [validation record](results/export-layer-0.16.md) contains the tested revisions and results.
The upstream subset passes 254 tests in each of four configurations.
The handoff copy passes both release modes with the export active, including its live socket tests.
