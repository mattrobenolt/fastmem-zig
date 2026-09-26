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
9. Inspect Zen 4 at 4–63 bytes and V1 at 33–64 bytes before acceptance.
10. Keep item 1 open until every required comparison meets the whole-interval rule.

These commands launch no instances.
The parent owns fleet execution, cross-family review, and final acceptance.
