# armg: Graviton mid-size dispatch, baseline memset, and the dist/small floor

Lane armg, 2026-09-26. Base: main `2afc101`. Lane branch
`pi-subagents/armg-138c818-267e-s0-t0`, tip `2236c7f`:

- `2bcb48d` — the SVE kernel mid-size rework (gaps 1a and 1b).
- `2236c7f` — the generic (baseline) memset rework (gap 2).
- This document, and the THIRD_PARTY.md attribution line for the
  memset-advsimd tail.

Fleet variant branch `fleet3/armg-midentry` = `ef0dc6c` (gap 3 lever;
flips `default_mid_entry`, one commit on top of `2236c7f`).

This host is Neoverse V3. All V1/V2 timing claims below are mechanism
plus fleet expectation, not measurements. Local runs compare against
glibc 2.42 (the fleet has 2.40), 8 samples x 5 ms, pinned to CPU 2;
cross-process drift on this box is about +-5% for C-ABI rows, so
sub-5% deltas below are marked as such. Evidence JSONL and the patched
binaries live in `.bench-cache/armg/`.

## Gap 1a: c9g copy misaligned/cross-lane 48-64 B (fleet 1.20-1.50)

Fleet rows (run `20260926T112106Z-smallmove-v1`, v1 = current main):
copy/misaligned/48 = 1.499 (1.82 vs 1.22 ns), /63 = 1.390, /64 = 1.328,
cross-lane/63 = 1.262, cross-lane/64 = 1.213.

Diagnosis. The V3 copy head is the neon tree; 33..64 fell into
mid_neon's four 16-byte chunk block (`ldr` x4 / `str` x4 at 0, 16,
n-32, n-16). glibc's `__memcpy_sve` at 33..128 runs the AOR ldp/stp
pair block (c9g glibc disasm, `__memcpy_sve+0x34`: `ldp q0,q1,[x1]`,
`ldp q2,q3,[x4,-32]`, `stp` x2). Locally reproduced exactly:
misaligned/48 = 6.00 vs 4.00 cycles (ratio 1.500, matching the fleet).
The inline layer's 33..64 class (two 32-byte chunks, which LLVM emits
as `ldp`/`stp` pairs) runs the same profile in 4.00 cycles with the
same branch count — so the cost is the chunk block's eight separate
16-byte accesses, not the size class or the dispatch. The chunk block's
aligned/page-offset wins (0.89-0.94) existed only because glibc's pair
block stalls on 4K aliasing there (glibc aligned/48 = 7.00 cycles vs
its own misaligned 4.00; the chunk block runs 6.5 on both). Parity on
those profiles is enough.

The residual after the pair swap (5.00 vs 4.00) was one
predicted-taken branch: the neon head reaches 33..64 through
`cmp 16; b.hs` + `cmp 32; b.hi` (two taken) against glibc's single
`b.hi` after the 2*VL compare.

Changes (`2bcb48d`):

- mid_neon's 33..128 is now the upstream pair block with the 128/64
  checks at its entry (instruction-identical to what glibc executes at
  these sizes). The gt64 inline alias keeps its semantics.
- The V3 copy head inverts the 32 test (`b.ls` to an out-of-line 16..32
  pair block) so 33+ falls through into the mid block: one fewer taken
  branch at 33..128 and above. 16..32 pays that branch instead; its
  local margin is 4.00 vs glibc 6.33 cycles. V2 keeps the old layout —
  its move 16..32 rows already sit at 1.30x glibc. The V3 move head
  cannot fall through (separate function) and is unchanged.

Local result (3-run medians, cycles, fastmem/glibc):
misaligned/48 6.00 -> 4.00 (1.000), misaligned/63-64 0.99/0.92,
cross-lane/63-64 0.97-0.99, aligned/48-64 land at 1.00-1.01 (the
give-back, as designed). The c9g move gap1/31/33 and bwd-gap31 rows at
64 B (fleet 1.05-1.09) measure 0.997-1.002 locally now.

Remaining in this area: copy page-offset/255 and aligned/255 (fleet
1.09-1.14) measure 1.06-1.08 locally after the change (from 1.12); the
residual is the tree-first `b.hs` every >= 16 B call pays against
glibc's single 128 check — the deliberate trade that keeps 1..3 B at
zero taken branches. move/disjoint/255 (fleet 1.12) is unchanged
locally at 1.03; the V3 move head keeps three taken branches to the
long path.

## Gap 1b: c7g move 96-256 B (fleet 1.09-1.43)

Fleet rows: move/disjoint/96 = 1.125, /127 = 1.271, /128 = 1.422
(3.85 vs 2.70 ns), fwd-half and fwd-gap4096 identical, /256 = 1.091.
Copy at the same sizes runs 0.96-1.07.

Diagnosis. V1 move uses the hybrid head; n > 2*VL (64 on V1) branched
to mid_neon's gt32 entry, which re-runs the 128/64 checks the head
already implies — one more taken branch and two more instructions than
glibc's `__memmove_sve` path (c7g glibc disasm: `cmp 128; b.hi` then
`cntb; cmp 2*VL; b.hi` into the shared mid block at
`__memcpy_sve+0x34`). Fastmem's own copy reaches the same mid block in
fewer branches and runs 2.89 ns at 128.

Change: the hybrid head checks 128 itself and routes (2*VL, 128]
straight to `.Lfm_sve_cpy32_128` (the SVE mid block), matching glibc's
memmove shape exactly (glibc's entry also checks 128 first). The pair
path (16..2*VL) pays one extra not-taken `cmp`. V1 no longer emits
mid_neon at all, so the gt64 alias is absent there (root.zig already
guards on `has_gt64_entry`; the mid-entry variant below is a no-op on
V1). Not locally measurable; V1 guards pass under qemu with
`sve-max-vq=2` (28,047,836 cases).

Watch item for the fleet: V1 move 16..64 must not regress from the
extra cmp (the pair path is at parity there today), and V1 copy rows
should be byte-identical in their live paths — only dead code left the
symbol.

## Gap 2: baseline (generic) memset vs glibc on Graviton

Fleet rows (run `20260926T044944Z-final-baseline`): set 0-16 = 1.20
(c7g) / 1.43 (c8g) / 0.83 (c9g); 65-256 = 1.09/1.14/1.14;
257-1K = 1.17/1.16/1.16. G6 (vs compiler-rt) already passes everywhere
(0.03-0.67).

Diagnosis, 0-16 B. Per-case, the tier is driven by n=0 (1.33-1.67 on
V1/V2), 1..3 (1.25-1.67), 4..15 (1.17-1.33). The upstream memset.S
tree pays 2-3 predicted-taken branches there (b.lo into the tree, tbz
chain, cbz for zero) where glibc's `__memset_sve_zva64` pays one
(`b.lo` into whilelo/st1b). A generic build cannot use the predicated
SVE store — that is the structural limit of this comparison — but the
branch count is closable.

Diagnosis, 129 B-1 KiB. Local generic-build runs showed a constant
~+4 cycles per call versus the SVE kernel at every size from 129 B to
64 KiB with identical instruction counts (aligned/192: 10.98 vs 7.07;
aligned/16384: 517.7 vs 513.4). The upstream memset.S tail (two
pre-stores `[x0]`/`[x3,16]`, the ungated ZVA check at >128, and the
[x3,32]/[x3,64] store loop) versus the memset-sve.S tail (256-byte ZVA
gate, one pre-store, [x3,16]/[x3,48] loop). I did not isolate the
microarchitectural mechanism (store-to-line completion order is the
suspect); the SVE-shaped tail removes the entire delta, and that tail
contains no SVE instructions, so the generic build may use it.

Changes (`2236c7f`, both in `src/aarch64/memset_advsimd.zig`): the
below-16 tree inverts to the layout the SVE kernel's neon body already
ships (cbz first; 1..3 falls through every branch — taken branches go
3->1 at n=0, 2->0 at 1..3, 2->1 at 4..15); the >128 tail now follows
AOR memset-sve.S at the same pinned commit (attribution updated in the
file header and THIRD_PARTY.md).

Local generic-build result: 0-15 B drops to 0.50-1.00 (n=0: 1.66 ->
1.00), 16-64 B stays 0.98-1.03 (that range pays the tree-first b.hs,
the same trade the SVE neon body ships at 0.89-0.90 fleet-wide),
129-1024 B drops to 0.99-1.01, and everything larger stays 1.00.
Compiler-rt margins remain >= 0.5x at every measured size. If a 0-16 B
gap to glibc survives on V1/V2 after this, it is the SVE predicated
store, which a no-SVE build cannot express — that remainder is the
documented structural gap, not a regression.

The same tree inversion applied to `memcpy_advsimd.zig` would address
baseline copy 0-16 (fleet 1.21/1.57 on c7g/c8g), but that head checks
16 first only by trading a taken branch onto 17-64, where the fleet
margin is 0.98-1.00 — too thin to touch blind. Left for a lane with
fleet access.

## Gap 3: dist/small on Graviton (G4 target 0.90)

Fleet: copy 1.10/1.01/0.96, move 1.08/0.98/0.98, set 1.10/1.01/0.98
(c7g/c8g/c9g).

New evidence, branch counters. The bench binary's perf group counts
cycles+instructions; I patched it locally (never committed) to count
branches and branch-misses on aarch64. Two host quirks found on the
way, relevant if branch counters ever join the harness: this vPMU
fails to schedule a four-event group (all counters read zero), and
opening branch-misses as a group *member* with `disabled=0` fails
EINVAL on this kernel (members must open disabled and rely on the
group enable ioctl).

dist/small mispredicts on V3, per call (median of 6 x 5 ms samples):
copy: glibc 0.0005, fastmem_abi 0.0004, fastmem_inline 0.0014;
move: ~0.04 for every impl (the shared-buffer overlap workload, not
dispatch); set: 0.0005-0.001. The 4096-entry fixed sequence is learned
by the predictor — the armd lane's mispredict hypothesis is disproven
on V3: even at 20 cycles per miss, 0.0014 misses/call is 0.03 cycles.

Local cycles per call after the kernel changes (glibc 2.42):
copy 8.30 glibc / 7.82 abi / 7.74 inline (0.933); move 15.87 / 15.57 /
15.60 (0.983); set 8.04 / 7.89 / 7.90 (0.983). The kernel changes
above already bought copy about 0.2 cycles versus the pre-change 7.94
the armd lane recorded.

The mid-entry alias on top of that: copy/dist/small inline branches
drop 8.09 -> 6.99 per call with cycles unchanged (7.74 both ways, 6
samples, +-0.5% repeat runs). No local win — the fall-through head
already removed one of the two branches the alias skips. It ships as
fleet variant branch `fleet3/armg-midentry` (`ef0dc6c`) because the
documented benefit was always a V2 mechanism (predicted-taken branch
cost on c8g); V1 no longer has the alias.

Structural floor, stated plainly: on V3 the >64 B half of dist/small
(56% of calls) is a kernel call for both sides, and the <= 64 B inline
half saves the call but pays the gate plus the class tree — under
random offsets the two nearly cancel (abi 7.82 vs inline 7.74). The
0.90 target needs 7.47 cycles per copy call on this box; the only
untested direction left was inlining 65..256, and armd measured that
losing (7.95 -> 9.00). With this harness and distribution the V3 floor
is about 0.93 copy and 0.98 move/set against glibc 2.42; the c9g fleet
numbers (0.96-0.98 against 2.40) already sit at that floor. Nothing
measured here moves c7g copy/set dist/small (1.06-1.10): the V1 live
copy path is unchanged, and its inline half already wins its fixed-size
tiers (0.56/0.72), so the gap lives in the mix itself — the kernel
beats the inline layer under random sizes there (armd's table), and no
lever survives contact with that fact on the evidence I can produce
locally.

Not addressed (leftover from the small-move follow-up, different
levers): c8g move 16-32 at ~1.30 (the +0.33 ns taken branch into the
exact-16 class), c8g move 0-3 at 1.10-1.16, c9g move fwd-gap1/15 at
1.06.

## Validation

| Check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 test-generic-set` | 348/348 steps, 38/38 tests |
| `zig build install` all 7 bench.toml rows + x86_64/generic baselines | pass |
| Native guards, V3 build, this host | 28,047,836 cases pass (run twice: at `2bcb48d` and at lane tip) |
| Native guards, generic build, this host | 28,047,836 cases pass (covers the new ZVA gating: values 0/0x5a/0xff through 1 MiB) |
| qemu guards, V1 build (`-cpu max,sve-max-vq=2`) | 28,047,836 cases pass |
| qemu guards, V2 build (`-cpu max,sve-max-vq=1`) | 28,047,836 cases pass |
| V1 build with `-Dmid-entry=on` (variant branch path) | builds; alias absent, falls back to the plain entry |
| `ziglint src/` | same 18 pre-existing findings |
| Arm kernel-byte gate | re-pinned in each kernel commit, on purpose: V1 copy shrinks (dead neon mid removed, 496 -> 368 B), V1/V3 move heads change (192 B both), V2/V3 copy carry the pair mid block (496 -> 464, 528 -> 496), generic set 288 -> 348 B; x86 and generic copy/move bytes untouched |
| `src/bench_fastmem.zig` | reverted to HEAD; the branch-counter patch was never committed |

## Fleet commands (no instance launches here)

```sh
cd /Users/matt/code/worktrees/fastmem-zig/pi-worktree-138c8182-b7bd-45d6-931c-0650fe0135e0-s0-0

# 1. Correctness on the Graviton fleet (target and baseline CPUs).
nix develop . -c just bench-test \
  --target c7g --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug

# 2. Target-cpu A/B (gaps 1a, 1b, and the dist/small movement).
nix develop . -c just bench-run \
  --rev main --rev pi-subagents/armg-138c818-267e-s0-t0 --cpu target \
  --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-mid

# 3. Baseline-cpu A/B (gap 2).
nix develop . -c just bench-run \
  --rev main --rev pi-subagents/armg-138c818-267e-s0-t0 --cpu baseline \
  --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-baseline

# 4. Optional: the mid-entry variant (V2/V3 only; no-op on V1).
nix develop . -c just bench-run \
  --rev pi-subagents/armg-138c818-267e-s0-t0 --rev fleet3/armg-midentry \
  --cpu target --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-midentry

nix develop . -c just b analyze <run-dir>
```

Read first in run 2: c9g copy misaligned/cross-lane 48-64 (expect
~1.0 from 1.20-1.50), c9g copy 16-32 (the inversion's cost side; local
margin is 4.00 vs 6.33 cycles), c7g move 96-256 (expect ~1.0-1.1 from
1.09-1.43) and c7g move 16-64 (must hold 1.00), c8g move 33-64 (the
pair block swap; G3 margin vs compiler-rt was 0.38-0.91), and every
c7g copy row (live code unchanged, layout shifted — drift check). In
run 3: baseline set 0-16 on c7g/c8g (expect <= ~1.0 from 1.20/1.43),
65-256 and 257-1K on all three (expect ~1.0 from 1.09-1.17), and
baseline set 16-64 (the tree-first trade; local 0.98-1.03).
