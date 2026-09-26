# Scorecard

The current state of fastmem against glibc 2.40 and compiler-rt (Zig 0.16)
on all seven targets. Update this file after each full-fleet run of main.

Runs: `bench-results/20260926T040226Z-final-standard/` (target CPUs),
`...044944Z-final-baseline/` (x86_64 / generic), `...053625Z-final-large/`
(large suite). Main abc998d. Standard suite, 6 rounds, A/A on, layout-clean
revisions and THP arena. Correctness: `bench-results/20260926T032704Z-test/`,
42/42 (7 targets x target and baseline CPU x Fast/Safe/Debug).

Noise floors (A/A, median / p90, target suite): c7i 1.16/4.21, c8i
0.37/1.77, c7a 0.81/18.08, c8a 0.68/6.94, c7g 0.30/1.72, c8g 0.41/4.04,
c9g 0.18/1.89 (%). c7a's fat tail (18%) is under investigation; c7i is
noisier than usual this run.

Ratios: time ratio, geometric mean per tier (0-16 / 17-64 / 65-256 /
257-1K / 1K-16K / >16K bytes). Below 1 means fastmem is faster.

## Target CPUs

fastmem_abi / glibc (G2):

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.69 0.79 0.95 1.10 1.01 1.00 | 1.15 1.23 1.02 1.06 1.01 1.00 | 0.91 0.90 1.00 0.98 0.99 1.00 | 0.97 1.00 1.00 1.01 0.99 0.87 | 1.00 1.00 1.00 1.00 0.99 1.00 | 1.00 1.00 1.00 1.00 1.00 1.00 | 0.53 0.80 1.01 1.00 1.00 1.00 |
| move | 0.72 0.93 0.99 1.02 0.99 0.40 | 1.07 1.10 1.02 1.00 0.99 0.40 | 0.87 0.93 0.96 0.95 0.99 0.99 | 0.95 1.02 0.99 0.98 0.99 1.00 | 0.85 1.00 1.04 1.00 1.01 1.00 | 0.90 1.04 1.00 1.00 1.00 1.00 | 0.59 0.99 1.00 1.00 1.00 1.00 |
| set | 0.46 0.45 0.91 1.02 1.00 1.00 | 0.51 0.47 1.00 1.01 1.01 1.00 | 0.49 0.48 1.10 1.00 1.00 1.02 | 0.50 0.50 1.06 1.01 1.00 1.00 | 1.00 0.89 1.01 1.00 1.00 1.00 | 1.00 0.89 1.00 1.00 1.00 1.00 | 0.59 0.89 1.00 1.00 1.00 1.00 |

fastmem_abi / compiler-rt (G3):

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.93 0.98 0.60 0.71 0.61 0.87 | 1.33 1.04 0.44 0.69 0.59 0.88 | 1.33 1.13 0.79 0.94 0.94 0.98 | 1.04 0.96 0.85 1.04 0.93 0.98 | 0.85 0.78 0.84 0.86 0.96 0.97 | 0.78 0.78 0.90 0.88 0.97 0.99 | 0.78 0.88 0.89 0.88 0.96 0.95 |
| move | 1.04 0.79 0.73 0.80 0.65 0.97 | 1.12 0.75 0.70 0.81 0.67 0.98 | 1.14 0.63 0.42 0.76 0.93 0.96 | 0.97 0.66 0.53 0.75 0.89 1.03 | 0.89 0.74 0.75 0.71 0.92 0.92 | 0.82 0.57 0.68 0.72 0.86 0.89 | 0.79 0.64 0.69 0.79 0.91 0.93 |
| set | 0.75 0.28 0.09 0.05 0.03 0.11 | 0.85 0.29 0.07 0.05 0.03 0.12 | 1.04 0.39 0.12 0.08 0.07 0.07 | 0.90 0.36 0.10 0.04 0.03 0.04 | 0.72 0.28 0.12 0.07 0.06 0.06 | 0.53 0.20 0.11 0.07 0.06 0.06 | 0.55 0.19 0.11 0.07 0.06 0.06 |

fastmem_inline / glibc (G4), plus dist/small:

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.51 0.82 0.84 1.02 1.00 1.00 | 0.76 0.73 0.96 0.99 1.01 1.00 | 0.83 0.62 0.87 1.04 1.01 1.00 | 0.64 0.54 0.99 1.15 1.00 0.88 | 0.56 0.72 0.99 1.00 1.00 1.00 | 1.09 0.98 1.00 1.00 1.00 1.00 | 0.52 0.68 1.02 1.02 1.00 1.00 |
| move | 0.69 0.96 0.99 1.09 1.00 0.40 | 0.82 0.89 1.03 1.02 0.99 0.40 | 0.89 0.81 1.02 1.07 0.99 0.99 | 0.75 0.79 1.01 1.09 1.01 1.00 | 0.53 0.78 1.01 1.00 1.01 1.00 | 0.93 0.89 1.03 1.00 1.00 1.00 | 0.56 0.75 1.01 1.01 1.00 1.00 |
| set | 0.65 0.43 0.76 1.05 1.02 1.00 | 0.27 0.21 0.73 1.02 1.02 1.00 | 0.52 0.35 0.81 1.00 1.00 1.02 | 0.28 0.21 0.65 0.95 1.00 1.02 | 0.29 0.52 0.98 0.99 1.00 1.00 | 0.66 0.73 1.00 1.00 1.00 1.00 | 0.33 0.74 1.00 1.00 1.00 1.00 |

dist/small, inline / glibc (single value): copy 0.34 / 0.45 / 0.66 / 0.85 /
1.10 / 1.01 / 0.96; move 0.86 / 0.81 / 1.21 / 0.99 / 1.08 / 0.98 / 0.98;
set 0.71 / 0.58 / 0.54 / 0.44 / 1.10 / 1.01 / 0.98.

## Baseline CPUs (runtime dispatch, x86_64 / generic)

fastmem_abi / glibc:

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.67 0.95 1.30 1.11 1.00 1.00 | 0.92 1.27 1.58 1.09 1.00 1.00 | 0.81 1.00 1.13 0.99 0.99 1.00 | 0.97 1.13 1.17 1.05 0.99 0.87 | 1.21 1.00 1.01 1.00 1.00 1.00 | 1.57 0.98 1.00 1.00 0.99 1.00 | 0.84 0.68 0.99 1.00 1.00 1.00 |
| move | 0.69 1.03 1.10 1.02 0.98 0.40 | 0.88 1.08 1.17 1.02 0.98 0.40 | 0.79 0.98 1.04 0.97 0.99 0.99 | 0.95 1.03 1.03 0.97 0.97 1.00 | 0.86 1.01 1.01 1.00 1.01 1.00 | 0.99 1.00 1.00 1.00 1.00 1.00 | 0.78 0.89 1.00 1.00 1.00 1.00 |
| set | 0.34 0.59 1.29 1.06 1.00 1.00 | 0.33 0.54 1.59 1.05 1.00 1.00 | 0.43 0.53 1.24 1.00 1.00 1.02 | 0.49 0.57 1.06 0.97 1.01 1.02 | 1.20 0.90 1.09 1.17 1.02 1.00 | 1.43 0.89 1.14 1.16 1.02 1.00 | 0.83 0.89 1.14 1.16 1.03 1.00 |

fastmem_abi / compiler-rt (G6):

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.91 0.98 0.56 0.47 0.37 0.86 | 0.91 0.99 0.61 0.48 0.36 0.81 | 0.96 1.15 0.73 0.65 0.54 0.92 | 1.01 1.07 0.77 0.62 0.46 0.84 | 0.98 0.74 0.62 0.47 0.46 0.61 | 1.12 0.74 0.72 0.47 0.54 0.70 | 1.11 0.69 0.66 0.46 0.52 0.62 |
| move | 0.99 0.82 0.82 0.67 0.43 0.91 | 1.00 0.83 0.84 0.68 0.42 0.90 | 1.05 0.75 0.91 0.83 0.57 0.68 | 0.96 0.75 0.78 0.70 0.48 0.69 | 1.07 0.67 0.70 0.52 0.53 0.68 | 1.20 0.65 0.73 0.53 0.54 0.66 | 1.16 0.65 0.73 0.55 0.52 0.63 |
| set | 0.61 0.38 0.11 0.05 0.03 0.11 | 0.62 0.36 0.11 0.05 0.03 0.12 | 0.98 0.44 0.13 0.08 0.07 0.07 | 0.80 0.39 0.11 0.04 0.03 0.04 | 0.67 0.13 0.06 0.04 0.03 0.03 | 0.53 0.09 0.06 0.04 0.03 0.03 | 0.54 0.09 0.06 0.04 0.03 0.03 |

## Goal status

- G1 (correctness): PASS, 42/42 on hardware (target and baseline builds).
- G2 (parity with glibc): PASS rows: c8a set, c7g copy/set, c8g copy/set,
  c9g move/set. FAIL rows are specific cases, not tiers (see below).
- G3 (never slower than compiler-rt): set PASS on c7i, c8i, c7g, c8g, c9g.
- G4 (inline <= 0.90 glibc on dist/small): PASS on x86 copy/set (0.34-0.85);
  FAIL on Graviton (0.96-1.10) and x86 move (0.81-1.21).
- G5 (export layer): PASS (docs/results/export-layer-0.16.md).
- G6 (baseline not slower than compiler-rt): PASS for set on c7i, c8i, c8a.
  copy/move FAIL on specific small rows (0-16 B is 0.96-1.20).

## Open gaps (next work, ordered)

1. Small moves on every target: 0-16 B move rows sit at 1.04-1.37 against
   glibc (backward and small-gap forward rows dominate), and at 0.97-1.20
   against compiler-rt. This is the largest coherent gap left.
2. c8i copy 0-64 B (1.15-1.23 vs glibc; the medium-entry cost from
   p3-x86e). Copy/move 257-1K on Intel (1.06-1.11).
3. c7a set 65-256 (1.10) and copy 17-64 vs compiler-rt (1.13-1.15).
4. Baseline builds vs glibc at 65-256 B (1.13-1.59): the dispatched level
   entry skips the scalar ladder, and the remaining gap to the comptime
   build needs a pass.
5. c7a noise tail (p90 18%) and c7i run-to-run spread (median floor 1.16%
   this run): investigate before small-effect work on those two.
6. c7g copy/misaligned 127-128 B (1.07-1.15) and c9g misaligned 48-128 B
   (1.20-1.50); c7g move fwd-gap31 16-31 B (1.83).
7. c8a copy >16K vs compiler-rt (1.15): the large suite run of
   final-standard vs final-baseline shows the dispatch and comptime paths
   equal (move/fwd rows fixed 1.00-1.01); the remaining >16K copy rows are
   the temporal loop.
