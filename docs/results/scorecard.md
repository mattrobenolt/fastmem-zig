# Scorecard

The current state of fastmem against glibc 2.40 and compiler-rt (Zig 0.16)
on all seven targets. Update this file after each full-fleet run of main.

Run: `bench-results/20260925T033508Z-scorecard/` (main 766db69). Standard
suite, 6 rounds, A/A on. It is the first full run with the fixed-size
revision label (no code-layout confound) and the THP arena (schema v3).
A/A noise floor, median / p90: c7i 0.72 / 4.24%, c8i 0.41 / 2.13%, c7a
0.22 / 1.90%, c8a 0.34 / 1.62%, c7g 0.27 / 1.55%, c8g 0.32 / 2.21%, c9g
0.20 / 1.51%. (Before the arena, AMD p90 was 7-11%.)

Correctness: `bench-results/20260925T030038Z-test/`, 42/42 (7 targets x
target and baseline CPU x ReleaseFast, ReleaseSafe, Debug).

Ratios are time ratios, geometric means of fixed profiles by size tier:
0-16 / 17-64 / 65-256 / 257-1K / 1K-16K / >16K bytes. Below 1 means
fastmem is faster.

## fastmem_abi / glibc (G2)

| Target | copy | move | set |
|---|---|---|---|
| c7i | 0.62 0.81 1.08 1.09 1.00 1.00 | 0.65 0.93 1.03 1.01 0.99 0.40 | 0.41 0.47 1.00 1.06 1.00 1.00 |
| c8i | 0.85 1.11 1.28 1.07 1.00 1.00 | 0.81 1.05 1.10 1.01 0.98 0.40 | 0.39 0.49 1.32 1.05 1.00 1.00 |
| c7a | 0.91 0.89 1.00 0.98 0.99 1.00 | 0.87 0.93 0.98 0.97 0.99 0.99 | 0.49 0.48 1.09 1.00 1.00 1.02 |
| c8a | 0.97 1.00 0.99 1.00 0.98 1.02 | 0.95 1.01 0.99 0.98 0.98 1.04 | 0.46 0.49 1.01 0.98 1.00 1.00 |
| c7g | 1.00 1.00 1.01 1.00 0.99 1.00 | 0.85 1.00 1.04 1.00 1.01 1.00 | 1.02 0.89 1.00 1.00 1.00 1.00 |
| c8g | 1.00 1.00 1.00 1.00 1.00 1.00 | 0.91 1.04 1.00 1.00 1.00 1.00 | 1.00 0.89 1.00 1.00 1.00 1.00 |
| c9g | 0.53 0.80 1.00 1.00 1.00 1.00 | 0.59 0.99 1.00 1.00 1.00 1.00 | 0.59 0.89 1.00 1.00 1.00 1.00 |

## fastmem_abi / compiler-rt (G3)

| Target | copy | move | set |
|---|---|---|---|
| c7i | 0.84 0.97 0.57 0.67 0.61 0.87 | 0.98 0.76 0.72 0.78 0.65 0.97 | 0.69 0.31 0.10 0.06 0.03 0.11 |
| c8i | 0.84 0.97 0.63 0.69 0.60 0.89 | 0.97 0.75 0.75 0.78 0.65 0.98 | 0.70 0.32 0.10 0.05 0.03 0.12 |
| c7a | 1.30 1.14 0.78 0.94 0.96 0.99 | 1.18 0.60 0.42 0.75 0.94 0.96 | 1.06 0.40 0.12 0.08 0.07 0.07 |
| c8a | 1.01 0.96 0.84 1.03 0.97 1.15 | 0.97 0.59 0.52 0.75 0.91 1.07 | 0.75 0.37 0.10 0.04 0.03 0.04 |
| c7g | 0.85 0.78 0.84 0.86 0.96 0.97 | 0.88 0.71 0.75 0.71 0.92 0.92 | 0.77 0.28 0.12 0.07 0.06 0.06 |
| c8g | 0.78 0.78 0.91 0.88 0.97 0.99 | 0.82 0.58 0.69 0.72 0.86 0.89 | 0.53 0.20 0.11 0.07 0.06 0.06 |
| c9g | 0.78 0.88 0.89 0.88 0.96 0.95 | 0.79 0.66 0.70 0.79 0.92 0.93 | 0.55 0.19 0.11 0.07 0.06 0.06 |

## fastmem_inline / glibc (G4)

| Target | copy | move | set |
|---|---|---|---|
| c7i | 1.20 0.84 0.88 1.02 | 1.07 0.93 0.97 1.04 | 0.66 0.43 0.76 1.08 |
| c8i | 0.74 0.69 0.92 0.99 | 0.80 0.88 1.01 1.02 | 0.27 0.21 0.73 1.05 |
| c7a | 0.83 0.62 0.86 1.03 | 0.89 0.81 0.92 1.01 | 0.51 0.35 0.81 1.00 |
| c8a | 0.57 0.51 0.98 1.12 | 0.67 0.74 0.98 1.07 | 0.35 0.23 0.61 0.95 |
| c7g | 0.60 0.71 0.98 1.00 | 0.56 0.78 1.01 1.00 | 0.30 0.52 0.98 0.99 |
| c8g | 1.16 0.99 1.00 1.00 | 0.97 0.90 1.03 1.00 | 0.66 0.73 1.00 1.00 |
| c9g | 0.55 0.68 1.02 1.02 | 0.59 0.74 1.01 1.02 | 0.33 0.74 0.99 1.00 |

(first four tiers; dist/small copy inline/glibc: 0.86 / 0.90 / 0.98 / 0.97
/ 1.00 / 1.02 / 1.02 in target order.)

## Summary

- Above 1 KiB, fastmem equals glibc on every op and target, and Intel large
  forward-overlap moves are 2.5x faster (0.40).
- memset is 8-30x faster than compiler-rt above 64 B everywhere. memcpy
  and memmove are 1.1-2.4x faster than compiler-rt in the mid sizes.
- Small sizes: often much faster than glibc (x86 set at 0-64 B 0.39-0.49,
  c9g 0-16 B 0.53-0.59, Intel copy 0-16 B 0.62-0.85).
- Goals: G1 PASS. G2 PASS: c8a set, c7g copy/set, c8g copy/set, c9g
  move/set. G3 PASS: set on c8i, c8a, c7g, c8g, c9g. The failing rows are
  listed below. G4 fails (the 0.90 target is not met on `dist/small` for
  most targets). G5 PASS (docs/results/export-layer-0.16.md). G6: measured for baseline
  builds after P7 (runtime dispatch, 61e3ba4). fastmem_abi/compiler-rt at
  0-16 / 17-64 / 65-256 B, baseline build on the x86 targets: c7i 1.03 /
  0.82 / 0.70, c8i 1.02 / 0.83 / 0.70, c7a 1.11 / 0.89 / 0.76, c8a 1.01 /
  0.97 / 0.84 (copy; move and set similar). Above 1 KiB it is 0.37-0.92.
  set passes on c8a; copy and move fail on a few small rows (0-3 B entry
  overhead, c8a 192 B and 64-256 KiB, c7a 511/768 B). P7b fixes those.
  The baseline builds above run the c8a 64 MiB forward-overlap kernel
  path 1.5-1.8x slower than compiler-rt; the same applies to the comptime
  znver5 build, so it is a kernel gap, not a dispatch one. P7b covers it.

## Open gaps (next work)

1. c8i 65-256 B: copy 1.28, set 1.32, move 1.10 against glibc
   (medium-first rework, docs/results/p3-x86d.md).
2. c7a 0-16 B against compiler-rt: copy 1.30, move 1.18, set 1.06; also
   copy 17-64 B 1.14.
3. Inline layer slower than the C-ABI kernel at 0-16 B copy on c7i (1.20)
   and c8g (1.16).
4. Intel 257-1K B: copy 1.07-1.09, set 1.05-1.06.
5. c8a >16K against compiler-rt: copy 1.15, move 1.07.
6. G4 `dist/small`: inline/glibc is 0.86-1.02, not 0.90 or less.
