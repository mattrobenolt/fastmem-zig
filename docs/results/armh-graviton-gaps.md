# armh: the remaining Graviton gaps

Lane armh, 2026-09-28. Base: main `6135cac`. Lane branch
`pi-subagents/armh-0ed03b8-e1b1-s0-t0`, tip `b45e58d`:

- `0cb3bf3` — the V3 copy 97..128 dispatch rework (gap 1).
- `ce61677` — the `hybrid_n32` head machinery (gap 2), default off.
- `b45e58d` — the `hybrid_ft` head machinery (gap 4), default off.

Fleet variant branches (one-line default flips plus the GOLDEN re-pin
of the bytes the flip changes, on purpose):

- `fleet3/armh-move-neon32` = `7b915e8` (V1 move = hybrid_n32).
- `fleet3/armh-v1move-ft` = `5db5da9` (V1 move = hybrid_ft).

This host is Neoverse V3 (c9g's core), glibc 2.42; the fleet runs 2.40.
V1/V2 timing is unverifiable locally; their claims below are mechanism
plus fleet expectation. Local runs: pinned to CPU 2, interleaved
base/head processes, 4-8 samples x 5-8 ms. Cross-process drift on this
box is about +-5% for C-ABI rows (unchanged 1 MiB long-path rows moved
+-5-9% between the A/B binaries); sub-5% deltas are marked as such.
Evidence JSONL and the A/B binaries live in `.bench-cache/armh/`.

## Gap 1: c9g copy 97..128 (fleet misaligned/127 = 1.086, cross-lane/127 = 1.130)

Fleet rows (run `20260927T162241Z-final-standard`, abi/glibc):
cross-lane/127 = 1.130 [1.095, 1.208] (3.48 vs 3.05 ns; the only
remaining G2 case violation in the class), misaligned/127 = 1.086,
aligned/128 = 1.022, page-offset/128 = 1.019. Vs compiler-rt,
misaligned/127 = 1.352 and misaligned/128 = 1.201 (G3 failures).

Diagnosis. glibc's `__memcpy_sve` at 33..128 is the AOR pair block, on
2.40 (fleet) and 2.42 (this host) identically — the disassembly differs
from upstream only in the entry nop/bti. At n = 127 both sides execute
the same four `ldp` pairs and four `stp` pairs at the same addresses;
the data path is not the gap. The gap is dispatch: the V3 neon head
reached the 65..128 block in 25 instructions / 2 taken branches
(tree-first `cmp 16; b.hs`, the 32 test, the 128 test, two end-pointer
adds computed in ge16 and thrown away, then the block recomputed them),
against glibc's 21/2 (`cntb`, `cmp 128; b.hi`, `cmp 2*VL; b.hi`).

Change (`0cb3bf3`). The V3 copy head's ge16 block is now pure dispatch
(the 32 and 128 tests, exactly 16 bytes) and falls into a new mid96
block that dispatches 96/64; 65..128 splits into two self-contained
blocks (65..96 and 97..128, the latter keeping glibc's load/store set
and order), so neither sub-class pays the other's boundary compare.
Executed path at 97..128: 20 instructions / 2 taken branches — one
instruction under glibc's budget. 65..96: 18/2 (was 21/3, one taken
branch gone). 33..64: 16/1 (was 18/1; the wasted adds are gone, one
not-taken cmp96 added). 16..32: 12/2 (unchanged; le32 computes its own
end pointers now). >128: 7/2 (was 9/2). The gt32/mov_gt32 entries keep
their shape and branch into the split tail, so the V3 move entry's
33..64 chunk path is byte-shape-identical; V2's mid keeps the same
dispatch (its 65..96 gains the fall-through, losing a taken branch).
V1 emits no neon mid block; its bytes are unchanged.

Local V3 (per-process abi/glibc medians, 4 interleaved processes each,
cycles; the two middle columns are the four base and four head runs):

| case | base runs | head runs | med base | med head |
|---|---|---|---|---|
| copy/aligned/128 | 1.105 1.111 1.109 1.114 | 1.007 1.000 1.003 1.007 | 1.110 | 1.005 |
| copy/page-offset/128 | 1.106 1.117 1.097 1.111 | 0.993 1.001 0.993 0.997 | 1.108 | 0.995 |
| copy/aligned/127 | 0.966 0.965 0.966 0.967 | 1.009 1.012 1.011 1.011 | 0.966 | 1.011 |
| copy/page-offset/127 | 0.965 0.965 0.967 0.964 | 1.009 1.009 1.010 1.010 | 0.965 | 1.010 |
| copy/cross-lane/128 | 1.015 1.012 1.022 1.032 | 0.997 0.986 1.012 0.987 | 1.018 | 0.992 |
| copy/cross-lane/127 | 1.008 0.994 1.040 0.998 | 1.013 0.980 1.022 1.009 | 1.003 | 1.011 |
| copy/misaligned/127 | 0.961 0.981 1.011 1.025 | 0.954 0.944 1.016 1.018 | 0.996 | 0.985 |
| copy/misaligned/128 | 0.940 0.951 0.913 1.005 | 1.015 0.989 1.047 0.982 | 0.946 | 1.002 |

The 127/128 flip is deterministic (+-0.002 across processes) and is
**not** an instruction effect: within each binary, 127 and 128 execute
identical instruction sequences, so opposite movement is whole-binary
layout luck of the kind armd's diagnosis 1 documented (mechanism still
unknown). The head binary lands within 1.2% of glibc at both sizes on
aligned/page-offset; the base binary won 127 and lost 128 by the same
layout luck. dist/small copy moved 0.982x base (small win, likely the
fewer instructions at 33..128). Watch rows held: misaligned/48 = 1.000
(the armg pair block), 33..64 within +1%, move 33..128 within noise.

Not closed: misaligned/127-128 vs compiler-rt (1.20-1.35). crt's
`memcpy` aligns the source to 32 bytes before its block loop, so three
of its four 32-byte loads avoid the line split that every one of ours
(and glibc's) pays at src_off = 1. Matching that needs the alignment
prologue (about five instructions) on the 65..128 path, which spends
exactly what this change saved on the aligned profiles. Left as the
documented residual; glibc pays the same cost, so G2 holds.

Fleet expectation: c9g copy cross-lane/127 and misaligned/127 improve
by the removed dispatch work; aligned/page-offset 128 move toward 1.00;
aligned/page-offset 127 give back the base build's layout luck (fleet
0.969-0.976, expect ~1.01 — under the 1.10 case bar either way). If the
fleet shows the flip instead, the dispatch model is wrong somewhere
new; the bytes are pinned, so the A/B is decisive.

## Gap 2: c7g move fwd/bwd-gap31 at 16..31 (fleet 1.17-1.83x compiler-rt)

Fleet rows (same run, c7g move, abi): fwd-gap31/24 = 5.61 ns,
fwd-gap31/31 = 5.64, bwd-gap31/16-31 = 4.74-4.75 — 1.17-1.83x
compiler-rt (3.08-4.07 ns), significant, G3 failures. G2 holds at 1.00
throughout: glibc's `__memmove_sve` runs the identical SVE pair and
pays the same 4.75-5.65 ns.

Diagnosis. The V1 hybrid move head routes 16..2*VL (64 on V1) to the
predicated SVE pair: `cntb; cmp 128; b.hi; cmp 2*VL; b.hi; whilelo x2;
ld1b x2; st1b x2; ret` — 12 instructions, one taken branch. The inline
layer's NEON pair runs the same cases in 1.16 ns (fleet
fastmem_inline). The pair is fast only when both addresses are aligned
(disjoint/16-31: 2.31 ns, 0.75-0.81x compiler-rt) and degrades with
active-lane count past 16 (fwd-gap31/16 = 2.42 ns vs fwd-gap31/24 =
5.61 ns, same alignments) and with a misaligned store (bwd-gap31/16 =
4.74). This is the V1 masked-store behavior p3-armc documented at 1..3;
at 16..31 the tier target min(glibc, compiler-rt) is compiler-rt, whose
disjoint-forward path runs plain 16-byte vector pairs in 3.08 ns.

Variant (`fleet3/armh-move-neon32`). New head `hybrid_n32`: the tree
below 16 unchanged (the 1..3 class has zero G3 margin on V1 and keeps
its zero-taken-branch shape), 16..32 routed out of line to an
overlapping 16-byte NEON pair (the move flavor keeps the exact-16
single transfer; loads precede stores, so any overlap stays correct),
33..2*VL falls through to the unchanged SVE pair dispatch. The 33+ path
pays one extra not-taken `cmp 32; b.ls`. Expected on V1: the five
failing gap31 rows drop from 4.7-5.7 ns to about 1.4-1.7 ns (0.4-0.55x
compiler-rt); disjoint 16..31 improve from 2.31 toward ~1.5 ns; 33..64
moves by at most the not-taken compare. The same mechanism sits inside
c7g move dist/small (abi 1.125x glibc — the shared-buffer mix exercises
misaligned 16..31 moves), so watch that row too.

Correctness: the V1-variant build passes the full guard matrix
(28,047,836 cases) under qemu `sve-max-vq=2`. The head is VL-agnostic
(runtime `cntb`); on a 128-bit-VL build the SVE pair's range is empty
and harmless.

## Gap 3: baseline (generic) set 0-16 vs glibc — documented structural gap

Fleet per-case rows (run `20260927T171003Z-final-baseline`,
abi/glibc): c7g every row 0..16 = 1.000; c9g 1..15 = 0.50-0.62 (we win:
the predicated SVE store is slow on V3); **c8g 1..15 = 1.17-1.21**
(1.26-1.29 vs 1.07 ns), 0 and 16 = 1.000. Vs compiler-rt the tier
passes with margin 0.16-0.72 on c8g (G6 is the baseline goal; it
holds).

The remaining gap is one mechanism: glibc's `__memset_sve_zva64` fills
1..15 with `dup; cmp 16; b.lo; whilelo; st1b; ret` — six instructions,
one store. The generic build has no SVE, so the advsimd memset runs the
inverted store tree: 13-14 instructions, 0-1 taken branches, 3-4
stores. The ~0.2 ns delta on V2 is the instruction count. No no-SVE
shape closes it (a shorter tree needs wider stores, which guard-page
tails forbid at 1..3). Locally the generic build on this V3 host runs
set 1..15 at 0.50x glibc and 0.08-0.60x compiler-rt
(`.bench-cache/armh/generic-set.jsonl`), consistent with the fleet's
c9g rows. armg's gap-2 note predicted exactly this remainder; it is the
documented structural gap, not a regression. No code change.

## Gap 4: dist/small on the Gravitons (G4 target 0.90)

Fleet (abi/glibc, inline/glibc): c7g copy 1.047/1.070, move
1.125/1.033, set 1.023/1.119; c8g copy 0.997/1.014, set 1.001/1.009;
c9g copy 0.942/0.943, move 0.978/0.983, set 0.984/0.984.

- c9g sits at armg's measured floor (0.93 copy, 0.98 move/set); the
  gap-1 change moved local copy dist/small 0.982x base. No lever left
  that survives measurement on this host (armd: inlining 65..256 loses;
  armg: the mid-entry alias is branch-neutral here).
- c7g move abi 1.125 carries the gap-2 mechanism (misaligned SVE pairs
  at 16..31 in the shared-buffer mix); `fleet3/armh-move-neon32` is the
  measurement.
- c7g copy/set inline vs abi: the inline layer beats the kernel at
  every fixed size locally (set <= 64: 6-7 executed instructions per
  call against the abi path's 22-24, cycles 1.5-2.0 vs 3.0-3.5) yet
  loses on V1's dist mix (set 1.119 vs 1.023). Nothing locally
  measurable distinguishes them: the instruction counts and the class
  shapes are the same as V3's, where inline ties abi (0.984 both). The
  standing suspicion is armd's diagnosis-1 layout sensitivity on V1.
  No code change; documented so the next lane does not re-derive it.
- The `hybrid_ft` variant (`fleet3/armh-v1move-ft`) is armg's
  documented-untried V1 move head with >= 16 on the fall-through: zero
  taken branches in the head for 16..2*VL and the mid/long dispatch,
  targeting the c7g move disjoint/fwd-gap4096/fwd-half 96..128 rows
  (1.10-1.21x glibc, G2 case violations). Predicted to break G3 at
  1..3 (the class sits at exactly 1.000x compiler-rt and pays the taken
  `b.lo`; p3-armc measured that shape at 1.33x on V3). Run it after the
  neon32 read; reject if 1..3 moves.

## Validation

| Check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 test-generic-set` at `b45e58d` | pass (exit 0) |
| Native guards, V3 build, this host, at `0cb3bf3` | 28,047,836 cases pass |
| qemu guards, V2 default build (`sve-max-vq=4`; its copy bytes changed with the tail split) | 28,047,836 cases pass |
| qemu guards, V1 + `-Dsmall-move=hybrid_n32` (`sve-max-vq=2`) | 28,047,836 cases pass |
| qemu guards, V1 + `-Dsmall-move=hybrid_ft` (`sve-max-vq=2`; same binary content as `5db5da9`) | 28,047,836 cases pass |
| `zig build install` all 7 bench.toml rows + baselines | pass |
| Arm kernel-byte gate | re-pinned per commit on purpose: V2 copy 480->528, V3 copy 576->672, V3 move hash (branch targets only; mid96 moved the shared body). V1 and generic unchanged on the lane branch; variant branches re-pin their V1 move bytes |
| `ziglint src/` | 19 findings (18 pre-existing + one more instance of the flagged `head_*` naming pattern) |
| x86 | untouched; codegen-x86 and test-dispatch pass |

## Fleet commands (no instance launches here)

```sh
cd /Users/matt/code/worktrees/fastmem-zig/pi-worktree-0ed03b89-5a57-4fff-9f61-20ae6135100f-s0-0

# 1. Correctness on the Graviton fleet (target and baseline CPUs),
#    lane tip and both variants.
git checkout b45e58d   # then repeat at 7b915e8 and 5db5da9
nix develop . -c just bench-test \
  --target c7g --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug

# 2. A/B/C/D: main, the lane, and the two V1 move variants.
nix develop . -c just bench-run \
  --rev main --rev b45e58d \
  --rev fleet3/armh-move-neon32 --rev fleet3/armh-v1move-ft \
  --cpu target --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armh

nix develop . -c just b analyze <run-dir>
```

Read first in run 2:

- c9g copy misaligned/cross-lane/page-offset/aligned 96-128, lane vs
  main: expect cross-lane/127 (1.130) and misaligned/127 (1.086) down,
  aligned/page-offset 128 to ~1.00, and aligned/page-offset 127 up to
  ~1.01 (the base build's layout luck returned). The accept criterion
  is the tier geomean and the case bar, not any single profile pair.
- c9g copy 33..64 and 16..32 and the c9g move rows 33..128 (watch
  rows; the move chunk path is byte-shape-identical, its 65..96 loses a
  taken branch).
- c7g move fwd/bwd-gap31 16..31 on `fleet3/armh-move-neon32`: expect
  1.17-1.83x -> about 0.4-0.6x compiler-rt. Watch c7g move 33..64 (one
  added not-taken compare) and c7g move dist/small (abi 1.125; the same
  mechanism).
- c7g move disjoint/fwd-gap4096/fwd-half 96..128 on
  `fleet3/armh-v1move-ft`: expect the 1.10-1.21x rows toward 1.0, and
  c7g move 1..3 (disjoint, gap1) to degrade toward 1.3x compiler-rt —
  that trade is the variant's accept/reject question.
- c8g everywhere: the V2 mid tail changed (65..96 loses a taken
  branch; 33..64 unchanged); expect parity or better, and treat any
  c8g copy/move 65..128 regression as news.
