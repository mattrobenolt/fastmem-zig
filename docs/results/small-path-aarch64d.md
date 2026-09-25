# Graviton inline layer, round 4: fetch-line slots and the mid-entry alias

Lane armd. Base: main `5e78ead` (the layout-clean scorecard run
`20260925T033508Z-scorecard`). Lane branch `pi-subagents/armd-...`:

- `55f1964` — the inline-loop layout fix (target 1).
- `93ec14f` — the mid-entry alias machinery, default off (target 2
  variant machinery + target-3-relevant for move).

Variant branch (only diff = the default selection):
`fleet3/armd-midentry` = `0a615db` (`default_mid_entry = true`).

This host is Neoverse V3 (c9g's core); V1/V2 timing is unverifiable
locally. Every V1/V2 claim below is a mechanism plus a fleet
expectation, not a measurement.

## Diagnosis 1: c8g inline copy 0-16 = 1.16 is a fetch-slot effect

The scorecard shows c8g (Neoverse V2) inline copy 0-16 at 1.16x glibc
while the C-ABI kernel measures 1.00 and c9g/c7g inline measure
0.55/0.60. Per-case fleet data (raw samples, c8g, copy/aligned,
inline ns vs glibc ~1.10 flat):

| n | 0 | 1..3 | 4 | 7 | 8 | 15 | 16 |
|---|---|------|---|---|---|----|----|
| ratio | 1.19 | 1.30 | 1.00 | 1.00 | 1.30 | 1.30 | 0.98 |

The same class split reproduces on all three Gravitons in absolute
time: classes {1..3, 8..15} run +0.30-0.35 ns over {4..7, 16..31}
(c9g: 1.216 vs 0.912 ns; c7g: 1.54 vs 1.17; c8g: 1.43 vs 1.09). It
only fails the tier on c8g because glibc's SVE pair runs in 1.10 ns
there (vs 1.9 on c9g, 2.3 on c7g) — fast enough to beat the slow
classes.

The runtime-size `runFastmemInline` copy instantiation is
instruction-identical between the `-Dcpu=neoverse_v2` and
`neoverse_v3` builds (verified by mnemonic diff), so this is
microarchitecture, not codegen. Ruling out the body, on this V3 host:

- perf counters: the slow 8..15 class executes **22 instructions in
  4.01 cycles**; the fast 16..31 class executes the same 22 in 3.00. A
  stall, not extra work.
- Swapping the 8..15 body to d-register (`@Vector(8,u8)`) loads/stores
  changes nothing (still 4.00).
- Isolated single-class loops show no delta; 4K-aliased src/dst in
  isolation shows no delta. The stall needs the full dispatch loop.

The mechanism, from the disassembly of the pristine instantiation:
each class is a separate basic block, and the slow classes are exactly
those whose block starts in the last 8 bytes of a 64-byte fetch line:

| class | entry mod 64 | V3 | V2 |
|---|---|---|---|
| 16..32 | 8 | fast | fast |
| 4..7 | 12 | fast | fast |
| 33..64 | 40 | fast | fast |
| kernel call | 44 | — | — |
| 1..3 (fallthrough) | 56 | fast | slow |
| n==0 | 56 | fast | slow |
| 8..15 | 60 | slow | slow |

Inserting one `nop` into the harness loop (local diagnostic, not
shipped) shifts every block by 4 bytes and 8..15 drops from 4.01 to
3.00 cycles. So: a class block entered at a fetch-line end costs one
cycle per loop iteration; V3 pays it only for taken-branch targets at
mod 60-63, while V1/V2 also pay for fallthrough/mod-56 entries (which
is why {0, 1..3} are slow only on c7g/c8g).

## Fix 1 (`55f1964`): invert the inline gate, mark the kernel call cold

In `fastmem.copy`/`move`/`set` (src/root.zig) the gate becomes
`if (bytes > max_inline) { @branchHint(.unlikely); kernel; return }`.
The 7-instruction kernel-call block moves out of the hot region, and
the class blocks land at fetch-line offsets 0-48 in all three ops'
runtime instantiations (verified by disassembly; only the n==0
epilogue remains at mod 60 — it was at 56 before and already slow on
V2, so no regression; possible small residual on the n==0 rows).

Local V3 (pinned, cycles/iter): copy/aligned and move/disjoint at
every size 0..31 run 3.00 (8..15 was 4.01); 33..64 and above
unchanged; set unchanged; the comptime const-size loops are
instruction-identical (only padding and constant-pool address diffs);
x86_64 znver5 `.text` byte-identical to main.

Fleet expectation: c8g inline copy 0-16 → ~1.0-1.05 (from 1.16);
c8g inline move 0-16 (0.97) improves too; c7g/c9g unchanged (they
already won these rows; the fix removes their hidden +1-cycle classes
as well, so they may improve slightly).

## Diagnosis 2: dist/small is structural parity (target 2)

The case (`src/bench_fastmem.zig`): size = min of two uniform 0..256
draws (so 44% of iterations are ≤ 64 B), random src/dst offsets ≤ 127,
a 4096-entry sequence. Splitting the distribution with
`--dist-file` histograms (baseline binary, local V3, cycles/iter):

| subpopulation | glibc | inline | ratio |
|---|---|---|---|
| ≤ 64, true skew | 4.60 | 4.48 | 0.978 |
| > 64, true skew | 12.01 | 12.00 | 0.998 |
| full 0..256 skew | 11.55 | 11.53 | 1.000 |

Two components, neither fixable with this design:

1. The 56% of iterations above 64 B call the same kernel that glibc
   runs (the fastmem kernel bodies are instruction-identical to
   glibc's SVE kernels at these sizes). Parity by construction.
2. Below 64 B the class tree's data-dependent branches mispredict at
   the same rate as glibc's size cascade (~0.7 mispredicts per call
   each — the class distribution has ~1.6 bits of entropy and both
   cascades are near-optimal binary trees). The inline win is the
   call overhead only, ~2%. The one branch-free guard-safe form (SVE
   predication, which is why glibc's small path is a single
   predicated pair) cannot be inlined: `asm volatile` defeats
   comptime constant folding, and the non-volatile form is
   deletable/movable — the reverted aarch64c attempt measured this.

Tried and rejected locally: extending the inline cap to 256 with
loop-free overlapping 32-byte chunk classes (65..128: four chunks,
129..256: eight). dist/small copy got **worse** (7.95 → 9.00
cycles/iter): the 129..256 chunks lose to the kernel's SVE long path
(fixed rows 192: 1.37x, 255: 1.10x — duplicate/overlapping stores
cost), and the extra `n <= 128` branch adds mispredicts. The kernel
call for > 64 B is already good. Not shipped.

The 0.90 G4 target stays unproven on aarch64; per the plan it was set
without supporting measurement.

## Variant (`fleet3/armd-midentry`): mid-entry alias for > 64 B calls

The one remaining lever: the inline layer's > 64 B call enters the
kernel at its entry, which re-runs the small-size dispatch the inline
gate already decided — `cmp 16; b.hs` + `cmp 32; b.hi` (neon head) or
`cntb` + `cmp 2*VL; b.hi` (hybrid/sve heads). Those branches are
predicted-taken on every such call, and a predicted-taken branch is
measurable on Neoverse V2 at benchmark loop scale (the pre-be7a1f8
abi trampoline cost 1.283x on c8g 0-16 rows; the same +0.33 ns
signature is visible in the c8g hybrid-move 17..32 rows below).

`fastmem_sve_copy_gt64` is a hidden size-0 label at the shared neon
mid block (`.Lfm_sve_cpy_gt32`), valid for any n > 64 and any
overlap: the 33..128 chunk blocks load before they store, and > 128
still routes to the long path's backward/forward dispatch. No
instruction bytes change (GOLDEN unchanged; check_kernel_bytes.py
skips the alias symbol with a comment). With the variant's default,
inline copy and move calls for n > 64 enter there instead.

Local V3 (pinned back-to-back A/B, cycles/iter, alias off → on):
copy/aligned/96: 7.00 → 6.57; /127: 8.03 → 7.59; /128: 8.00 → 7.42;
move/disjoint/96: 7.00 → 6.55; move/disjoint/128: 8.00 → 7.3;
copy/dist/small: 8.00 → 7.87; 129..256 fixed and move/dist/small
neutral. The V3 effect is small because predicted-taken branches are
nearly free there; the mechanism targets V1/V2.

Fleet expectation: c8g/c7g inline 65-256 rows and dist/small improve
by the skipped predicted-taken branches (up to ~0.3 ns each on V2);
c9g ~neutral (small local win). If the A/B shows nothing, the lane
default (off) keeps the machinery dormant.

## Diagnosis 3: the listed move rows are the hybrid-head price (target 3)

c8g move 17-64 = 1.04: the spikes are disjoint/gap33/gap4096 at
24/31/32 (1.30x glibc). Disassembly: glibc `__memmove_sve` at n=24
executes 11 instructions with zero taken branches
(nop/cmp128/cntb/cmp2VL/pair/ret); fastmem's hybrid head executes the
same pair behind `cmp 16; b.hs` — one predicted-taken branch =
+0.33 ns on V2 = the 1.30x. The hybrid head exists because the tree
below 16 fixes the V2 gap1 1..3 forwarding stalls (3.86x compiler-rt
with the pure SVE head, aarch64c). The alternative layout (b.lo, tree
out of line) was measured by aarch64c to cost the 1..3 class the same
cycle, and 1..3 gap1 is the G3-critical case. The tier passes G2
(1.04 ≤ 1.05). Left as is — a fix needs a head that enters the tree
without a taken branch, and no such aarch64 shape exists.

c7g move 65-256 = 1.04: spikes at disjoint/fwd-gap4096 96..128
(1.09-1.42x) inside the upstream mid/backward dispatch on V1. Not
locally verifiable (V1); tier passes G2. Not touched.

## Validation

- `zig build test`: pass on the lane branch (default off) and with
  `-Dmid-entry=on` (the variant's default).
- Guard suite, ReleaseFast, `-Dmid-entry=on`: 28,047,836 cases pass.
- `zig build install` builds for neoverse_v1/v2/v3, aarch64 generic,
  x86_64 znver5; also the all-sve override combo
  (`-Dsmall-copy=sve -Dsmall-move=sve`, alias absent → fallback).
- Kernel bytes: GOLDEN unchanged (the alias is a label; the checker
  skips `fastmem_sve_copy_gt64` explicitly).
- x86_64 znver5 bench-fastmem `.text`: sha256-identical to main
  (all changes are comptime-gated to aarch64).
- `ziglint src/`: only pre-existing findings.

## Fleet commands

```sh
just bench-up c7g c8g c9g
just b test --target c7g --target c8g --target c9g \
    --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
just bench-run --rev 5e78ead --rev 93ec14f --rev 0a615db \
    --target c7g --target c8g --target c9g --suite standard --rounds 8 \
    --label p3-armd
```

Expectations:

- c8g inline copy 0-16: 1.16 → ~1.0-1.05 at 93ec14f; move 0-16
  improves; nothing else moves (layout fix is inline-only).
- c7g/c9g: unchanged or slightly better on the same rows; watch for
  layout accidents (the fix is a re-layout — spot-check the tiers).
- `0a615db` vs `93ec14f`: 65-256 inline copy/move rows and dist/small
  on c7g/c8g improve by the skipped predicted-taken branches; c9g
  ~neutral. Reject the variant if it does not beat the lane beyond
  noise.
