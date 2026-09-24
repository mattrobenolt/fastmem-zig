# Export-layer validation: Zig 0.16.0

Date: 2026-09-24.
Host: launchpad, Linux aarch64, Neoverse V3.
Base revision: fastmem `11bf53f`.
The validation made no performance claim and launched no AWS instances.

## Binary matrix

`zig build test-export -j4 --summary all` passed all 100 build steps.
The step includes 28 linked images, two Debug objects, two linkage objects, and two expected compile failures.

| Hazard | Test | Result |
|---|---|---|
| Wrong provider | Final symbol address equals the stored `fastmem.abi` address | Pass |
| Weak export | Relocatable symbols are `GLOBAL HIDDEN` | Pass |
| Compiler-rt override | Runtime u128 division adds `__udivti3` without a provider change | Pass |
| glibc override | Both libc states retain the fastmem addresses | Pass |
| Kernel recursion | Direct branch audit of entries and Zig kernel helpers | Pass |
| Executable interposition | Three memory symbols absent from `.dynsym` | Pass |
| Shared-library interposition | Same absence in both ELF shared-library probes | Pass |
| C binding | Three separate C probes branch to the same ABI addresses | Pass |
| Accidental opt-in | Disabled controls bind to compiler-rt, not the ABI addresses | Pass |
| Unsupported backend | Both non-LLVM export attempts produce the expected compile error | Pass |

The runtime consumer tests pass natively on aarch64 and through `qemu-x86_64` on x86_64.
Debug with LLVM also passes the runtime tests.
The separate non-LLVM Debug objects show calls for copy and move on both architectures.
Their fill operation is a call on aarch64 and inline `rep stosb` on x86_64.

The glibc cross binaries receive static inspection only.
Zig 0.16 rejects static glibc links for these targets.
The native handoff tests provide runtime coverage with glibc and compiler-rt together.

## Standard library

Command:

```sh
nix develop -c zig build test-export-std
```

| Target | Mode | Result |
|---|---|---|
| Native Neoverse V3 | ReleaseFast | 254 passed |
| Native Neoverse V3 | ReleaseSafe | 254 passed |
| x86_64_v3, QEMU | ReleaseFast | 254 passed |
| x86_64_v3, QEMU | ReleaseSafe | 254 passed |

The selected tests cover these modules:

- `std.mem`
- `std.fmt`
- `std.sort`
- `std.array_list` and `std.multi_array_list`
- `std.hash_map` and `std.array_hash_map`
- `std.Io.Writer` and `std.Io.Reader`
- `std.crypto.hash.Blake3`

The count also includes anonymous declaration tests from imported standard-library modules.
Each binary passes the ABI-address and `.dynsym` checks before execution.

An ordinary wrapper that imports `std.mem` collects no `std.mem` tests.
A separate module whose root is `std/mem.zig` fails because the file belongs to two modules.
`src/export/std_tests.py` instead copies the standard-library tree into a temporary directory.
It adds a test-only comptime export block to `std/std.zig`.
The command uses that file as its root and supplies `--zig-lib-dir` for the private copy.
The original toolchain files remain unchanged.

The packaged `std/crypto/test.zig` file is empty in this toolchain.
SHA-2, SHA-3, and BLAKE2 tests fail to compile because their assertion helpers are absent.
Those tests are excluded, rather than rewritten.
The BLAKE3 reference vectors and parallel-versus-sequential tests pass unchanged.

## Handoff

Source revision: `148f2d7b101ec6e725dbdd052ff6e4f367f37ef4`.
The source came from `git archive` into `/tmp/fastmem-p6-handoff`.
The original handoff checkout remained unchanged.

The copy added the fastmem package dependency and imports to four roots:

- `src/main.zig`
- `src/test_backend.zig`
- `bench/load/main.zig`
- `bench/sink/main.zig`

Each root called `fastmem.exportSymbols()`.
Each root also exposed three ABI-address constants for binary inspection.
The copy removed only the competing export block from `src/memset.zig`.
Its original implementation and tests remained intact.

The first integration attempt exposed a fastmem package bug.
Private assembly probes replaced the public `fastmem` module with the last cross target, `aarch64-macos-none`.
`build.zig` now creates private modules with `b.createModule` and asserts the public module identity.

The first successful handoff runs still used its old strong `memset` definition.
The ABI-address checker detected that error.
The results below come from subsequent runs after removal of that competing export.

Commands, from the copy:

```sh
nix develop /tmp/fastmem-p6-handoff -c timeout 480 zig build test \
  -Doptimize=ReleaseFast -Dmode=tls -Dgit-commit=148f2d7-p6 \
  -Dstrip=false --summary all -j2

nix develop /tmp/fastmem-p6-handoff -c timeout 480 zig build test \
  -Doptimize=ReleaseFast -Dmode=plaintext -Dgit-commit=148f2d7-p6 \
  -Dstrip=false --summary all -j2

nix develop /tmp/fastmem-p6-handoff -c timeout 480 zig build test \
  -Doptimize=ReleaseSafe -Dmode=tls -Dgit-commit=148f2d7-p6 \
  -Dstrip=false --summary all -j2

nix develop /tmp/fastmem-p6-handoff -c timeout 480 zig build test \
  -Doptimize=ReleaseSafe -Dmode=plaintext -Dgit-commit=148f2d7-p6 \
  -Dstrip=false --summary all -j2
```

| Mode | TLS | Plaintext |
|---|---|---|
| ReleaseFast | 183 passed | 153 passed, 30 skipped |
| ReleaseSafe | 183 passed | 153 passed, 30 skipped |

Every run reports `12/12 steps succeeded`.
The 30 plaintext skips are the existing TLS-only gates.
No live socket test was disabled for this validation.
The main suite includes real handshakes, certificate reload, drain, timeout, and connect-cancel tests.
The other roots add 21 load-client tests, four backend tests, and nine sink tests.

The four main test images pass the ABI-address and `.dynsym` checks.
Their cache identifiers, in the same order as the commands above, are:

- `32a2cce1d4a3f5cab808afbcc80e7820`
- `ae26aa849084de3b4565ca07da77dd00`
- `b307ea2f1b719a1bb39aac3c8f47bef3`
- `0b53f07ae4d9d236498d08955486c7c1`

The PostgreSQL external gate, Python benchmark suite, and long soak did not run.
Handoff did not receive a production source change from this lane.

## Remaining limits

Non-LLVM exports remain unsupported.
The same-link replacement intentionally affects C objects.
A competing strong memory definition violates the API contract and can evade the assembler duplicate-symbol check.
Other object formats remain unsupported.
The validation does not establish performance parity or correctness on every fleet CPU.

## Repository checks

`zig build test -j2 --summary all` passed all 109 build steps and all 27 Zig tests.
`zig build -j2 --summary all` passed all nine build steps.
The modified Zig files pass `zig fmt --check` and `ziglint`.
The full `ziglint src/` command still reports 26 existing warnings in untouched kernel and assembly-probe files.
