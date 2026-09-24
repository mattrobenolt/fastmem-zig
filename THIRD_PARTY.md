# Third-party code

fastmem is MIT (`LICENSE`). This file lists every file that is a port of
upstream code, per the licensing rules in `docs/fastmem-plan.md`.

## Arm Optimized Routines

Upstream: https://github.com/ARM-software/optimized-routines
License: MIT OR Apache-2.0 WITH LLVM-exception (per-file SPDX header;
fastmem uses the MIT option). The upstream copyright and SPDX lines are
kept verbatim at the top of each ported file.

Pinned commit: `5e20a93f440ca771bcdb757cc13c3beee217e534`
(2026-09-15, newest commit touching `string/aarch64` at fetch time;
includes `23c4393006122497ea989725c9e34d253bc1e62b`, "Improve
__memcpy_aarch64_sve": the cntb hoist and `.p2align` layout).

| Ported file | Upstream file | Port |
|---|---|---|
| `src/aarch64/memcpy_sve.zig` | `string/aarch64/memcpy-sve.S` | Faithful translation to Zig container-level global asm; symbols renamed to `fastmem_sve_copy` / `fastmem_sve_move` with hidden visibility |
| `src/aarch64/memset_sve.zig` | `string/aarch64/memset-sve.S` | Same; symbol `fastmem_sve_set`; the runtime DCZID_EL0 check on the ZVA path is kept |
| `src/aarch64/memcpy_advsimd.zig` | `string/aarch64/memcpy-advsimd.S` | Same; symbols `fastmem_advsimd_copy` / `fastmem_advsimd_move` |
| `src/aarch64/memset_advsimd.zig` | `string/aarch64/memset.S` | Same; symbol `fastmem_advsimd_set`; the runtime DCZID_EL0 check on the ZVA path is kept |

Port-level deviations (each is documented in the file header): the
`asmdefs.h` macros (`ENTRY` / `ENTRY_ALIAS` / `END`, register aliases,
`L()`) are expanded by hand; the GNU_PROPERTY note (link-level BTI/PAC
marking) is omitted because no other object in a Zig link carries it;
the BTI landing pad (`hint 34`) is kept. No algorithmic change.
