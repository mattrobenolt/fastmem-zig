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

1. Small moves: fixed (d15e126, `bench-results/20260926T085954Z-smallmove`
   and `...112106Z-smallmove-v1`). move 0-16 B vs glibc: c7i 1.37 -> 0.72,
   c8i 1.33-1.59 -> ~0.90, c7a 1.12 -> 0.65, c9g 0.59 -> 0.57; c8g 17-64 B
   1.04 -> 0.96, c9g 17-64 B 0.99 -> 0.80. Neoverse V1 keeps the SVE small
   path (the NEON classes lost there at 48-64 B). vs compiler-rt: move 0-16 B
   0.76-0.96 on x86, 0.52-0.76 on Graviton.
2. c8i copy 0-64 B: fixed by x86f pairs (1.12/1.14 -> 0.87/0.96). c7i
   copy 65-256/257-1K: fixed by x86f chunks (1.10/1.09 -> 0.92/1.05).
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

## Small-move investigation, 2026-09-25

Base: `6922b55`. Worktree: `/Users/matt/code/fastmem-zig-small-moves`.
The lane has no fleet acceptance yet.

### Diagnosis

The x86 overlap-dispatch hypothesis is false for 0–64 bytes.
`src/x86_64/move.zig` reaches `source_inside` and the alias test only through `largeKernel`.
Every small class loads its complete source before its first store.
Gaps 0, 1, 16, 31, and 33 select identical instructions in both directions.
Identity moves still execute the transfers.

The SPR benchmark kernel starts at `0x10935f0` in `.bench-cache/small-moves/base/spr/bin/bench-fastmem`.
Its 4–15 class executes four dword loads and four stores, including duplicate endpoints.
Its 16–63 class executes four XMM loads and four stores.
The compact offset calculation adds five instructions to each class.
At 16 bytes, all four vector transfers reference the same address.
Granite Rapids adds its medium-first decision before the same small classes.
Zen 4 uses scalar endpoint pairs below 16 and vector endpoint pairs through 64.
Zen 5 uses the compact classes, like SPR.

The SPR compiler-rt `memmoveFast` entry is `memmove` at `0x10a9120` in the same binary.
Its 0–15 classes match the compact strategy.
Its 16–63 path also saves registers and spills vectors to its stack.
At 64 bytes, compiler-rt tests direction and enters its vector-loop setup.

The glibc x86 reference starts at `0x196380` in `.bench-cache/glibc/libc-x86_64-linux-gnu.so.6`.
It uses endpoint pairs for 4–7, 8–15, 16–31, and 32–63 bytes.
It performs no overlap decision through 64 bytes.
Its smaller classes pay more size decisions than fastmem, but avoid compact duplicate transfers.
The cached disassembly remains under `.bench-cache/glibc/`.

The V3 benchmark move entry starts at `0x10a5180` in `.bench-cache/small-moves/base/v3/bin/bench-fastmem`.
The scalar tree covers 0–15 bytes with byte triples and 4-byte or 8-byte endpoint pairs.
The hybrid head then uses two predicated SVE transfers through twice the runtime vector length.
V1 has a 32-byte vector length on the fleet. V2 and V3 have 16-byte vectors.
The next class uses four NEON vectors through 64 bytes.
All listed gaps and both directions follow identical paths below 65 bytes.
The inline classes in `src/aarch64/small.zig` use scalar and NEON pairs instead of SVE.

The V3 compiler-rt entry is `memmove` at `0x10a53a0` in that binary.
Its byte path takes 14 instructions through return. Fastmem takes 15, including BTI.
Compiler-rt uses four dword transfers for 4–15 bytes and four vectors for 16–63 bytes.
Its vector class also allocates a stack frame and stores vector snapshots there.
The glibc SVE reference starts at `0xaee80` in `.bench-cache/glibc/libc-aarch64-linux-gnu.so.6`.
Its small predicated path has no taken branch, unlike the fastmem hybrid head.

Instruction counts do not explain every gap-dependent timing result.
Repeated calls create dependencies between previous stores and subsequent source loads, even when each individual call is disjoint.
`docs/results/small-path-aarch64c.md` records the byte-size SVE forwarding failures and the rejected SVE inline experiment.
`docs/results/small-path-aarch64d.md` records layout sensitivity and the hybrid head cost at 17–32 bytes.
Neither record establishes a universal replacement for the hybrid head.

### Initial local evidence

`nix develop /Users/matt/code/fastmem-zig-small-moves -c just test` passes at the base.
ReleaseFast `install asm` builds pass for all seven CPU models, plus `x86_64_v3`.
The baseline binaries and disassembly reside in `.bench-cache/small-moves/base/`.
No AWS instance was launched.

### Candidate changes

Commits: `c36cd2e` changes x86. `802f5e3` changes aarch64 and adds the focused correctness matrix.
`ec217f9` records the initial diagnosis.
These commits are candidates, not seven-target performance acceptance.

The x86 ABI move entry is now `x86_64.move.moveKernel`.
The copy entry remains `x86_64.move.kernel`, with identical bytes on all four fleet models.
The new entry uses these classes:

- Zero returns without any access.
- Sizes 1–3 use the existing byte triple, with its size decision first.
- Sizes 4–7 use two 4-byte endpoints.
- Sizes 8–16 use two 8-byte endpoints.
- Sizes 17–32 use two 16-byte endpoints.
- Sizes 33–63 use two 32-byte endpoints.
- Sizes above 63 retain the existing medium and large transfer bodies.

The Granite Rapids entry retains its medium-first decision.
AVX-512 ABI classes use high registers at 33–63 bytes and need no `vzeroupper`.
The baseline dispatcher uses four SSE2 endpoints at those sizes.
Complete level entries and the inline move layer use the new classes too.
The bounded dispatch entries above 128 bytes remain unchanged.

Counts below include return and exclude the caller.
Each cell gives old/new executed instructions.
The concrete-length tracer in `src/x86_64/check_dispatch.py` produced the counts from the saved benchmark binaries.

| CPU | 0 | 1–3 | 4–7 | 8–16 | 17–32 | 33–63 | 64 |
|---|---:|---:|---:|---:|---:|---:|---:|
| SPR | 8/6 | 16/14 | 19/14 | 19/14 | 19/14 | 19/14 | 12/12 |
| GNR | 10/8 | 18/16 | 21/14 | 21/14 at 8, 19/14 at 16 | 19/14 | 19/14 | 10/10 |
| Zen 4 | 10/6 | 18/14 | 12/14 | 10/14 | 12/14 | 12/14 | 12/12 |
| Zen 5 | 8/6 | 16/14 | 19/14 | 19/14 | 19/14 | 19/14 | 12/12 |

Zen 4 is a specific regression risk.
Its original pair classes already avoid duplicate compact transfers.
The candidate trades extra decisions at 4–63 bytes for fewer decisions at 0–3 bytes.
Instruction counts alone cannot accept that trade.

The aarch64 ABI move default changes from hybrid to NEON on V1, V2, and V3.
The scalar tree below 16 bytes stays byte-identical.
An exact 16-byte class executes one vector load and one store.
Sizes 17–32 use the existing NEON endpoint design.
Sizes above 32 enter the shared NEON mid block directly.
The mid and long bodies do not change.

The V3 candidate keeps `fastmem_sve_move` at `0x10a5180` in `.bench-cache/small-moves/final/neoverse_v3/bin/bench-fastmem`.
Its new block starts at `0x10a5200`:

```asm
cmp    x2, #0x20
b.hi   fastmem_sve_copy_gt64
ldr    q0, [x1]
cmp    x2, #0x10
b.eq   exact16
add    x4, x1, x2
ldur   q1, [x4, #-0x10]
add    x5, x0, x2
str    q0, [x0]
stur   q1, [x5, #-0x10]
ret
exact16:
str    q0, [x0]
ret
```

The internal label name `copy_gt64` does not restrict this assembly branch.
It names the existing 33–128-byte block, which already handles this range for the NEON copy head.
Both loads precede both stores for every overlap direction.
The accesses stay inside the source and destination intervals.

At 16 bytes, the ABI instruction count falls from 13 to 10.
At 17–32 bytes, it rises from 13 to 14 despite the local timing improvement.
At 33–64 bytes, V2/V3 fall from 21 to 20 instructions.
V1 instead changes from 13 SVE instructions to 20 NEON instructions.
That V1 class requires fleet measurements.

### Rejected Arm experiments and inline scope

The tiny-first Arm experiment saves two instructions at 1–3 bytes but does not improve local timing there.
It increases disjoint 4–15-byte calls from 3 to 4 cycles.
The experiment was rejected.
Its source remains only in `.bench-cache/small-moves/arm-tiny-first.zig`.

A plain NEON pair fixes gap31 but retains duplicate stores at exactly 16 bytes.
Local forward-gap1/16 rises from 11.49 to 12.83 cycles.
The exact-16 class removes that regression.

The same exact-16 split in the inline layer improves forward-gap1/16 from 12.87 to 11.29 cycles.
It also increases disjoint and gap31 inline 24/31-byte calls from 3 to 4 cycles.
An unlikely branch hint does not remove that regression.
The supervisor accepted an ABI-only Arm fix and deferred the runtime inline exact-16 change.
The existing inline NEON classes remain unchanged.
A fixed 16-byte inline call already compiles to one transfer.

### Final local V3 timing

Run directory: `bench-results/20260926-local-small-moves/`.
Final samples are `final-control-{0..5}.jsonl` and `final-{0..5}.jsonl`.
The control is `6922b55`. The candidate contains `c36cd2e` and `802f5e3`.
Both binaries use `-Dcpu=neoverse_v3 -Doptimize=ReleaseFast -Drev=cmp`.

Each process uses one sample per implementation, a 5 ms sample target, and a 1 ms warmup.
Six process pairs alternate A/B order on the first permitted CPU through `os.sched_setaffinity`.
The selected profiles are disjoint and both directions of gap1 and gap31.
They cover every standard size, including sizes above 64 bytes.

These are exploratory local medians, not fleet confidence intervals.
The local resolver selects glibc 2.42, not the fleet glibc 2.40.
The raw metadata has no harness codegen attachment or A/A replica.
Therefore, these samples do not establish G2 or G3 acceptance.

| ABI case | Base cycles | Candidate cycles | Local glibc cycles | Local compiler-rt cycles |
|---|---:|---:|---:|---:|
| disjoint/16 | 6.278 | 4.007 | 6.277 | 10.040 |
| disjoint/24 | 6.275 | 4.002 | 6.276 | 10.041 |
| disjoint/32 | 8.376 | 4.003 | 8.366 | 14.001 |
| fwd-gap1/16 | 11.488 | 11.307 | 11.483 | 20.697 |
| bwd-gap1/16 | 11.574 | 11.423 | 11.571 | 21.590 |
| fwd-gap31/24 | 12.174 | 4.002 | 12.081 | 10.209 |
| bwd-gap31/24 | 11.219 | 4.002 | 11.220 | 9.717 |
| fwd-gap1/15 | 12.360 | 12.291 | 11.543 | 14.481 |

The last row remains approximately 1.065 times local glibc.
Thus this lane does not close the complete 0–16-byte target, even locally.
The unchanged inline disjoint/24 and gap31/24 cases remain at 3.00 cycles.
No selected ABI median rises by more than 5% at any standard size.
That observation is not a statistical regression gate.

The unchanged inline disjoint/1 MiB median rises from 45,704 to 48,168 cycles, or 5.4%.
The lane does not dismiss that shift as noise.
The fleet A/A run must distinguish layout or system effects from a repeatable regression.

### Local validation and byte preservation

| Check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 --summary all` | 348/348 steps, 37/37 unit tests |
| `zig build install` | Pass |
| ReleaseFast `install` for all seven `bench.toml` CPUs | Pass |
| Native guards, V1/V2/V3 builds on this V3 host | 28,047,836 cases each, pass |
| QEMU guards, `x86_64_v3` build | 28,047,836 cases, pass |
| QEMU guards, baseline build with detected v3 dispatch | 28,047,836 cases, pass |
| `ziglint src/` | 18 existing findings, no additional findings |
| Arm kernel-byte gate | Only move hashes deliberately changed |
| Copy/set ABI kernel bytes, all seven CPUs | Identical to `6922b55` |
| Fixed copy/set probes, four x86 fleet CPUs plus v3 | 512/512 byte-identical per CPU |
| Runtime copy/set graphs on those x86 CPUs | Identical instructions and destinations after address normalization |

Runtime probe bytes contain different relative call displacements because move changes the object layout.
No copy or set instruction changes beyond those displacements.
The complete copy/set graphs retain their original instructions.
The Arm copy/set hashes in `GOLDEN` remain unchanged.
The two new Arm move hashes retain the original 192-byte symbol size.

The focused unit test covers every length from 0 through 64.
It checks gaps 0, 1, 16, 31, and 33 in both directions at four offsets.
It compares all surrounding bytes through ABI and inline paths and checks the zero-length null-pointer return.
The x86 codegen gate now traces every small move length and rejects pointer-order tests, stack saves, and AVX-512 cleanup.
The dispatch gate compares each complete move entry against the corresponding comptime entry.

Evidence logs reside in `.bench-cache/small-moves/`.
The native Arm guards prove execution on V3, not performance or hardware behavior on V1/V2.
The QEMU guards do not execute AVX-512.
Fleet guards and cross-family review remain mandatory.

### Fleet procedure

1. Select the lane worktree.

```sh
cd /Users/matt/code/fastmem-zig-small-moves
```

2. Run correctness on the existing fleet.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just bench-test \
  --target c7i --target c8i --target c7a --target c8a \
  --target c7g --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
```

3. Compare the standard suite on all seven targets.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just bench-run \
  --rev main --rev WORKTREE --cpu target \
  --target c7i --target c8i --target c7a --target c8a \
  --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label small-moves-standard
```

4. Compare the filtered 24-byte forward-gap31 case.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just bench-run \
  --rev main --rev WORKTREE --cpu target \
  --target c7i --target c8i --target c7a --target c8a \
  --target c7g --target c8g --target c9g \
  --suite standard --filter move/fwd-gap31/24 --rounds 6 \
  --label small-moves-gap31-24
```

5. Compare the filtered 15-byte backward-gap1 case.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just bench-run \
  --rev main --rev WORKTREE --cpu target \
  --target c7i --target c8i --target c7a --target c8a \
  --target c7g --target c8g --target c9g \
  --suite standard --filter move/bwd-gap1/15 --rounds 6 \
  --label small-moves-gap1-15
```

6. Compare the baseline dispatch builds.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just bench-run \
  --rev main --rev WORKTREE --cpu baseline \
  --target c7i --target c8i --target c7a --target c8a \
  --suite standard --rounds 6 --label small-moves-dispatch
```

7. Analyze each returned run directory.

```sh
nix develop /Users/matt/code/fastmem-zig-small-moves -c just b analyze <run-dir>
```

8. Reject significant regressions, including copy, set, inline, and sizes above 64 bytes.
9. Inspect Zen 4 at 4–63 bytes and V1 at forward-gap1/16 and 33–64 bytes before acceptance.
10. Keep item 1 open until every required comparison meets the whole-interval rule.

These commands launch no instances.
The parent owns fleet execution, cross-family review, and final acceptance.


### Cross-family review follow-up, 2026-09-26

Opus found no correctness blockers in `d71d819` after disassembly-based emulation across every small overlap gap and both directions.
The review identified unnecessary taken branches in the x86 small entry.
The candidate now marks the `n >= 64` block in `moveKernel` unlikely.
This keeps 4–63-byte calls on the short fall-through path.
The Granite Rapids medium-first decision remains unchanged.

The following taken-branch counts come from the reviewer emulator on rebuilt SPR and Zen 4 binaries.
They exclude return and include jumps between blocks.

| Size | Before hint | After hint | Instructions after hint |
|---|---:|---:|---:|
| 1–3 | 0 | 0 | 14 |
| 4–7 | 3 | 2 | 14 |
| 8–16 | 2 | 1 | 14 |
| 17–32 | 3 | 2 | 14 |
| 33–63 | 4 | 3 | 14 |
| 64 | 1 | 2 | 12 |

The repeated emulator row covers lengths 0–130, every gap from `-n-2` through `n+2`, and four alignments.
Additional disjoint gaps are `±(n+1500)` and `±4096`.
Each CPU passes 72,836 cases with zero failures, no external exits, and a correct null-pointer zero-length return.
Every source load and destination store stays within its interval.
Logs reside in `.bench-cache/small-moves/review/emulator.log`.

The codegen gate now limits taken branches and tightens the 4–63-byte instruction budget to 14.
The SPR inline move branch-count gate now checks the new class tree.
The pointer-order check tracks pointer origins instead of register names.
It accepts `subq %rcx,%rdi` after LLVM repurposes `%rdi` for an offset.
Five focused tests cover scratch reuse and comparisons through pointer aliases.

Implementation names now distinguish the changed move code:

- Comptime x86 move: the existing tuning name plus `+move-pairs-v1`.
- Baseline x86 move: `x86-dispatch+move-pairs-v1`.
- Dispatched level name: the existing level name plus `+move-pairs-v1`.
- Arm NEON move: `aor-sve-5e20a93+small-neon-exact16-v1`.

Copy and set retain their implementation names.
The Arm hybrid and SVE overrides retain their names because their code does not change.
A unit test checks that the changed move names differ from copy.

The exact-16 comments now distinguish the rejected NEON pair from the previous hybrid head.
The hybrid head did not duplicate the 16-byte store: its second SVE predicate was empty.
The measured improvement versus that head covers 16–32 bytes.
The exact-16 class prevents the regression that the rejected plain NEON pair introduced.

The V1 forward-gap1/16 result in `src/aarch64/tuning.zig` remains relevant evidence against an unconditional replacement.
`docs/results/small-path-aarch64c.md` records 0.61 times compiler-rt for the old SVE path in `20260924T102308Z-p3-arm-small`.
That result supports the previous hybrid default, not the current NEON candidate.
The fleet watch list therefore includes V1 forward-gap1/16, alongside V1 33–64 bytes and Zen 4 4–63 bytes.

The review also identifies failures outside the changed classes in `20260926T040226Z-final-standard`:

- c8i disjoint 0–63 bytes retains the medium-first entry cost.
- c8g 0–3 bytes retains the scalar path.
- c9g forward-gap1 at 8, 15, 48, and 64 bytes retains the original transfer bodies.

These rows keep item 1 open regardless of the gap31 improvement.
The local timing table above predates the x86 branch hint and does not establish its performance effect.

Follow-up validation passes 348/348 build steps and 38/38 tests.
The command includes `test`, `test-export`, `test-dispatch`, and `codegen-x86`.
All seven ReleaseFast `install` rows pass.
The changed comptime `x86_64_v3` build passes 28,047,836 guard cases under `qemu-x86_64 -cpu max`.
The Arm kernel-byte gate still passes without another re-pin.
The exact fleet commands above remain the acceptance procedure.


### V1 carve-out after the fleet A/B, 2026-09-26

The run directory is `bench-results/20260926T085954Z-smallmove/`.
The NEON move candidate regressed c7g, so Neoverse V1 now restores the previous hybrid head.
It uses the scalar tree below 16 bytes and the SVE pair through `2*VL`.
V1 has a 256-bit SVE width, so the pair covers 16–64 bytes.
V2/V3 retain the new NEON classes.

The c7g report contains these `fastmem_abi/glibc` ratios:

| Case | v0: hybrid | v1: NEON candidate |
|---|---:|---:|
| disjoint/16 | 1.0001 | 1.1667 |
| fwd-gap1/48 | 1.0015 | 1.1464 |
| fwd-gap1/63 | 1.0016 | 1.1202 |
| fwd-gap1/64 | 1.0009 | 1.1333 |
| fwd-gap4096/48 | 1.0426 | 1.4358 |
| fwd-gap4096/63 | 1.0033 | 1.2971 |
| fwd-gap4096/64 | 1.0210 | 1.4732 |
| fwd-gap31/16 | 0.9999 | 1.1666 |
| fwd-gap31/24 | 1.0001 | 0.4795 |
| fwd-gap31/31 | 1.0002 | 0.4418 |

The carve-out gives up the V1 gap31/24 and gap31/31 wins to remove the broader regressions.
It restores the exact V1 move bytes from before `802f5e3`.
Only the V1 move entry changes in the Arm kernel pins.
V2 now has a separate move pin because it no longer shares V1's move bytes.
Copy and set remain unchanged on every model.

The existing implementation names distinguish the selected kernels:

- V1: `aor-sve-5e20a93+small-hybrid`.
- V2/V3: `aor-sve-5e20a93+small-neon-exact16-v1`.

The name test now covers the restored hybrid path.
The parent will repeat the fleet comparison on c7g, c8g, and c9g.
The carve-out does not constitute performance acceptance.


Validation passes 348/348 steps and 38/38 tests for `test`, `test-export`, `test-dispatch`, and `codegen-x86`.
`just test` and all seven ReleaseFast `install` rows pass.
All three Arm unit binaries also pass under QEMU, including the implementation-name test.

Each Arm model passes 28,047,836 QEMU guard cases through 1 MiB.
V1 uses `-cpu max,sve-max-vq=2`.
V2/V3 use `-cpu max,sve-max-vq=1`.
An independent `cntb` probe confirms vector widths of 32 and 16 bytes.

A byte comparison against the preceding candidate covers the ABI kernels on all seven targets.
Only V1 move differs, and its bytes match the pre-`802f5e3` binary exactly.
The evidence resides in `.bench-cache/small-moves/v1-carveout/`.
`ziglint src/` reports the same 18 existing findings.

## Large NT candidate, 2026-09-27

The baseline is `418197e`, measured in `bench-results/20260927T175720Z-final-large/`.
The assigned gaps are SPR copy/move at 64 MiB and Zen 5 set at 64 MiB.
This candidate has no fleet performance acceptance.

### Diagnosis

`src/x86_64/tuning.zig` gives Zen 5 no memset NT threshold at the baseline.
Its 64 MiB fill uses temporal stores, not the NT loop.
The candidate selects NT at 32 MiB and retains temporal stores below 32 MiB.
This threshold is experimental, not protection for a measured 16 MiB fill win.
The supervisor approved one additional threshold branch for large Zen 5 fills.
The existing small classes and temporal transfer body must remain unchanged.

The inspected binary is `.bench-cache/glibc/libc-x86_64-linux-gnu.so.6` in the main checkout.
Only behavioral observations follow. No glibc code enters this candidate.
The glibc NT fill body is unreachable on c8a.
Its `rep_stosb_threshold` is `0xffffffffffffffff`, per `docs/research/hosts/c8a/ld-diagnostics.txt:224`.
The branch at `0x196c47` therefore cannot reach either REP or the NT threshold check.
Section 1.8 of `docs/research/x86_64-design.md` documents the same AMD policy.

The c8a 64 MiB loss is temporal versus temporal, not NT versus NT.
The assigned `final-large` run reports 1.37–1.38 there and 1.02–1.03 at 16 MiB.
These ratios do not establish a temporal fill win at 16 MiB.
The NT candidate can still improve 64 MiB, but its crossover needs measurements.

- Memmove aligns NT destinations to 64 bytes after a temporal head store (`0x19673c`–`0x196753`).
- Its NT body interleaves two or four pages (`0x196780`, `0x196940`).
- Each page advances 128 bytes per inner iteration, with source prefetches ahead of the loads.
- One fence follows the bulk loop, before the temporal remainder (`0x196852`, `0x196a62`).
- Memset broadcasts the byte once at entry (`0x196c04`).
- Its NT loop writes four aligned cache lines per iteration, without prefetch (`0x196d55`).
- Its fence precedes four temporal tail stores (`0x196d7c`).

Fastmem instead uses one contiguous copy stream and one source prefetch per 256 bytes.
Each NT store has a separate assembly barrier and pointer operand in `ops.streamStore`.
The SPR candidate will group transfers and interleave two pages, with 256 bytes per page per iteration.
This is an independent loop design, not a translation of the inspected binary.
The Zen 5 candidate will group fill stores and broadcast outside the loop.

### Candidate and local evidence

Commit `48e155c` implements the candidate.
SPR retains its 53.5 MiB copy/move threshold and all overlap decisions.
Its NT loop processes independent 8 KiB tiles through one leaf call per tile.
Each inner step transfers 256 bytes from each page and prefetches eight source cache lines, 512 bytes ahead.
The tile leaf uses high AVX-512 registers and has no stack frame.
The outer loop fences once before its temporal remainder.

Zen 5 selects NT fills at 32 MiB.
Its NT loop broadcasts once and stores eight aligned cache lines per iteration.
One fence precedes its temporal remainder and final 64-byte store.
The large entry uses a conditional tail transfer, without a stack frame or additional call on temporal fills.

The codegen gate now follows both NT helper graphs.
Mutation tests reject absent NT stores, fences, or prefetches.
They also reject an incorrect Zen 5 threshold or broadcast count.
The dispatch gate checks the updated Zen 5 fill policy and equality with the comptime kernels.

| Local check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 --summary all` | 350/350 steps, 38/38 tests |
| ReleaseFast `install`, all seven fleet CPUs | Pass |
| ReleaseFast `install`, `x86_64_v3` | Pass |
| `qemu-x86_64 -cpu max`, static musl v3 guard binary, through 1 MiB | 28,047,836 cases, pass |
| `ziglint src/` | 18 existing findings, no new findings |
| Arm kernel-byte gate | All existing pins pass |

The GNU guard binary first failed because this Arm host lacks `/lib64/ld-linux-x86-64.so.2`.
A static musl build supplied the successful QEMU run.
QEMU does not execute the changed AVX-512 paths.
Fleet correctness remains mandatory.

### Preservation proof and explicit exceptions

All comparison binaries use `-Doptimize=ReleaseFast -Drev=largent`.
The control source is `418197e`.
Evidence resides in `.bench-cache/largent/` in the lane worktree.
The scripts are `identity.py` and `fixed.py`.
Their outputs are `identity.log` and `fixed.log`.
`install.log` records the whole-section comparisons.

The entire benchmark `.text` section matches exactly on these models:

- Granite Rapids
- Zen 4
- Neoverse V1
- Neoverse V2
- Neoverse V3
- `x86_64_v3`

All 768 fixed probes match exact instruction bytes on each x86 fleet model, v3, and v4.
SPR copy/move temporal graphs retain the same instructions and register allocation.
The proof normalizes addresses and padding, then excludes only the NT successor of the existing threshold decision.
The copy specialization reverses that decision from `jb` to `jae`, so the temporal path falls through instead.
SPR set and the complete Zen 5 copy/move graphs also match after address and padding normalization.

Zen 5 set necessarily adds one comparison and conditional branch above 512 bytes.
LLVM also changes register allocation and schedules the broadcast and return-register assignment differently.
Its temporal transfer body retains all 63 instructions after register-role normalization.
The stores, loop strides, unroll factors, and branch graph remain unchanged.
The proof checks the exact setup sequences separately.
The supervisor accepted these differences instead of another temporal wrapper.
Thus the affected models do not claim literal byte identity for every path through 16 MiB.

No AWS command ran in this lane.
Neither candidate has a measured speedup yet.
Two-page traversal can lose to another stream count or prefetch distance on SPR.
Zen 5 temporal calls also require a regression check because their large-entry branch and register allocation change.

### Review follow-up

Opus found no NT correctness defect across 272,408 modeled cases.
The review identified the missing Zen 5 guard coverage and the incorrect AMD glibc diagnosis.
Commit `69d8d1f` raises both Zen 5 guard ceilings to 33 MiB.
Commit `cfc851d` adds threshold samples and corrects the diagnosis above.
This follow-up does not change any kernel source.
The earlier whole-benchmark `.text` proof applies to the original kernel candidate, before the new benchmark cases.

The guard matrix still contains 28,047,948 cases at either 16 or 33 MiB.
Only its two sparse sizes above 1 MiB change.
They become 33 MiB minus one byte and 33 MiB, through runtime and ABI paths.
The first size also exercises a misaligned slice adjacent to the end guard.
Peak data allocation rises from approximately 160 MiB to 330 MiB.

One native V3 run took 68.39 seconds at 16 MiB and 70.52 seconds at 33 MiB.
These wall times describe local test cost, not Zen 5 performance.
The fleet timeout remains 600 seconds.
Debug and emulated runtimes can differ.

The large suite adds aligned and misaligned fills at these sizes:

- 24 MiB
- 32 MiB
- 48 MiB

The suite now has 66 cases, including 14 fill cases.
Copy and move retain their original four sizes.
The schema accepts the additional sizes only for fills.
Unit tests and native JSONL tests cover the six new cases.

The control revision is `5bce447da69077a3c99b1282e22229c921edff02`.
It contains the revised benchmark and guards on top of `418197e`, without any kernel change.
Its complete codegen-probe `.text` matches `418197e` for all four x86 fleet models, v3, and v4.
Both revisions therefore emit the same cases, and the A/B isolates the kernel candidate.
The original `418197e` binary cannot emit the new threshold samples.

### Temporal fill cause: unresolved hypothesis

The cause of the Zen 5 temporal loss remains unknown.
Both baseline AMD binaries use 32 ZMM stores per main iteration, or 2 KiB.
The loop starts at `0x1094fb0` on Zen 4 and `0x10950f0` on Zen 5 in the saved baseline binaries.
Both also have a four-store remainder loop.
The glibc temporal loop uses four ZMM stores per iteration, or 256 bytes.
Unroll factor alone therefore does not explain the difference between models.

The host diagnostics report the same 16 MiB shared-cache size on both AMD targets, at line 219.
Their reported L1 data sizes differ: 32 KiB on c7a and 48 KiB on c8a, at line 218.
These facts do not establish a causal explanation.

The hypothesis is that the larger unroll interacts differently with Zen 5 instruction delivery or store throughput.
An independent temporal-only 256-byte loop can test that hypothesis against the 2 KiB loop on both AMD targets.
That experiment must retain destination alignment and the same memory layout.
It must include the new threshold sizes and report cycles and instructions.
A Zen 5 improvement without a Zen 4 improvement will support, but not prove, the hypothesis.
The current NT candidate bypasses the loss above its threshold and does not fix the temporal loop below it.
A separate tuning-only comparison must also distinguish NT policy gains from gains due to `streamGrouped` itself.

### Follow-up validation

| Local check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 --summary all` | 350/350 steps, 39/39 tests |
| ReleaseFast `install`, all seven fleet CPUs | Pass |
| Control `test codegen-x86 install` | 354/354 steps, 39/39 tests |
| Python suite | 251 tests pass |
| Python lint, format, and type checks | Pass |
| Native guards at 16 and 33 MiB | 28,047,948 cases each, pass |
| QEMU v3 guard with forced NT thresholds at 8192 bytes | 28,047,836 cases, pass |
| `ziglint src/` | 18 existing findings, no new findings |
| Arm kernel-byte gate | All pins unchanged |

The QEMU build uses `-Dx86-nt-min=8192 -Dx86-memset-nt-min=8192` and a static musl target.
Disassembly confirms YMM NT stores, the 8192-byte comparisons, and fences in all three operations.
The guard matrix includes 8191, 8192, and 8193 bytes and extends through 1 MiB.
This run exercises the existing AVX2 NT paths, not the new AVX-512 helpers.
Only the fleet can execute those helpers with the revised 33 MiB ceiling.
Evidence resides in `.bench-cache/largent/followup/`.

### Parent fleet procedure

Select the lane worktree.

```sh
WT=/Users/matt/code/worktrees/fastmem-zig/pi-worktree-7bf04d56-9652-4f7a-9f4b-f22d893ead5d-s0-0
cd "$WT"
```

Run correctness on SPR and Zen 5.

```sh
nix develop "$WT" -c just bench-test \
  --target c7i --target c8a \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
```

Compare the revised large suite against the matched control.

```sh
nix develop "$WT" -c just bench-run \
  --rev 5bce447da69077a3c99b1282e22229c921edff02 --rev WORKTREE \
  --suite large --rounds 6 --label largent \
  --target c7i --target c8i --target c7a --target c8a
```

Check standard-suite regressions on both affected models.

```sh
nix develop "$WT" -c just bench-run \
  --rev 5bce447da69077a3c99b1282e22229c921edff02 --rev WORKTREE \
  --suite standard --rounds 6 --label largent-standard \
  --target c7i --target c8a
```

If a separate crossover run is necessary, select both fill profiles explicitly.

```sh
nix develop "$WT" -c just bench-run \
  --rev 5bce447da69077a3c99b1282e22229c921edff02 --rev WORKTREE \
  --suite large --rounds 6 --label largent-set-bracket --target c8a \
  --filter set/aligned/ --filter set/misaligned/
```

Avoid `--filter set/`, because substring matching also selects `copy/page-offset/`.
Analyze each returned run directory with `just b analyze`.
Reject significant regressions, including the 16 and 24 MiB fill controls.
Keep hardware correctness and performance acceptance open until these runs pass.
