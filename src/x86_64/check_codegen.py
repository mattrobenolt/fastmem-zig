"""Reject split vectors and external memory calls in the x86 probes."""
import argparse
from functools import cache
import json
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("cpu")
parser.add_argument("variant", choices=("entry", "high_regs", "tiered", "compact", "medium_first", "ymm_medium", "straight_1k"))
parser.add_argument("artifact")
parser.add_argument("--experiment", default="auto",
                    choices=("auto", "none", "medium_layout", "medium_entry", "small_paths", "x86f_pairs", "x86f_chunks", "x86f_zen4", "x86f_source", "x86f_dispatch", "x86f_temporal", "x86f_source64", "x86g_temporal", "x86g_medium"))
args = parser.parse_args()
cpu, variant, artifact = args.cpu, args.variant, args.artifact


def resolve_policy(cpu, experiment):
    """Mirror the per-model composition in tuning.zig, not the experiment label."""
    auto = experiment == "auto" or experiment.startswith(("x86f_", "x86g_"))
    return {
        "entry_pairs": cpu == "graniterapids" and auto,
        "medium_chunks": cpu in ("sapphirerapids", "graniterapids") and auto,
        "zen4_short": cpu == "znver4" and experiment == "x86f_zen4",
        "medium_entry": cpu == "graniterapids" and (auto or experiment == "medium_entry"),
        "short_scalar": cpu == "znver4" and experiment == "small_paths",
        "inline_short_first": cpu == "sapphirerapids" and (auto or experiment == "small_paths"),
        "source_64": cpu == "znver5" and auto,
        "nt_min": ((0x4000001 if experiment == "x86f_temporal" else 0x2000000)
                   if cpu == "znver5" else {
                       "sapphirerapids": 0x3580000,
                       "graniterapids": 0xf100000,
                       "znver4": 0xc00001,
                   }.get(cpu)),
    }


policy = resolve_policy(cpu, args.experiment)
medium_fallthrough = cpu == "graniterapids" and args.experiment == "x86g_medium"
temporal_set_256 = cpu == "znver5" and args.experiment == "x86g_temporal"
entry_pairs = policy["entry_pairs"]
medium_chunks = policy["medium_chunks"]
zen4_short = policy["zen4_short"]
medium_entry = policy["medium_entry"]
short_scalar = policy["short_scalar"]
inline_short_first = policy["inline_short_first"]
compact_variants = ("compact", "ymm_medium", "straight_1k")
reordered_variants = ("tiered", *compact_variants, "medium_first")
dis = subprocess.check_output(["llvm-objdump", "-dr", "--no-show-raw-insn", artifact], text=True)
nm = subprocess.check_output(["llvm-nm", "--defined-only", "--format=posix", artifact], text=True)
syms = {}
for line in nm.splitlines():
    fields = line.split()
    if len(fields) == 4 and fields[1].lower() == "t":
        syms[fields[0]] = (int(fields[2], 16), int(fields[3], 16))
instructions = {}
for line in dis.splitlines():
    match = re.match(r"\s*([0-9a-f]+):\s+([a-z].*)", line)
    if match:
        instructions[int(match[1], 16)] = match[2].split("#")[0].strip()


@cache
def body(name):
    start, size = syms[name]
    return [(a, i) for a, i in instructions.items() if start <= a < start + size]


def require(condition, message):
    if not condition:
        raise SystemExit(f"{cpu}: {message}")


def check_nt_frame(code):
    """Every path from a stack save must encounter an NT store before exit."""
    at = dict(code)
    following = {a: b for (a, _), (b, _) in zip(code, code[1:])}
    for start, insn in code:
        if not re.match(r"push|subq.*%rsp", insn):
            continue
        pending, visited = [start], set()
        while pending:
            pc = pending.pop()
            if pc in visited:
                continue
            visited.add(pc)
            text = at[pc]
            if text.startswith("vmovntdq"):
                continue
            require(not text.startswith("ret"), "non-NT large path saves registers")
            if text.startswith("j"):
                target = int(re.search(r"0x([0-9a-f]+)", text)[1], 16)
                require(target in at, "non-NT tail path saves registers")
                pending.append(target)
                if text.startswith("jmp"):
                    continue
            require(pc in following, "stack save reaches an unexpected exit")
            pending.append(following[pc])


def tests_pointer_order(text):
    """Track pointer origins, not register names that LLVM can reuse as scratch."""
    wide = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp"]
    narrow = ["eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp"]
    wide += [f"r{i}" for i in range(8, 16)]
    narrow += [f"r{i}d" for i in range(8, 16)]
    aliases = {f"%{a}": f"%{b}" for a, b in zip(narrow, wide)}
    registers = {f"%{r}" for r in wide}
    origins = {"%rdi": {"dst"}, "%rsi": {"src"}}
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        op = parts[0]
        operands = re.split(r",\s*(?![^()]*\))", parts[1])
        if len(operands) != 2:
            continue
        src, dst = operands
        left, right = origins.get(src, set()), origins.get(dst, set())
        if op in ("cmpq", "subq") and left and right and left != right:
            return True
        if op.startswith(("cmp", "test")):
            continue
        dest = aliases.get(dst, dst)
        if dest not in registers:
            continue
        if op == "movq":
            origins[dest] = left.copy()
        elif op == "leaq":
            origins[dest] = set().union(*(origins.get(r, set()) for r in re.findall(r"%\w+", src)))
        elif op in ("addq", "subq"):
            origins[dest] = left | right
        else:
            origins.pop(dest, None)
    return False


def class_path(name, n, stats=None):
    """Follow the kernel's size dispatch with concrete RDX and unknown pointers."""
    code = body(name)
    next_pc = {a: b for (a, _), (b, _) in zip(code, code[1:])}
    pc = code[0][0]
    flags = None
    visited = []
    taken_branches = 0
    for _ in range(100):
        insn = instructions[pc]
        visited.append(insn)
        op = insn.split()[0]
        if op.startswith("ret"):
            if stats is not None:
                stats["taken_branches"] = taken_branches
            return "\n".join(visited)
        cmp = re.fullmatch(r"cmp[ql]\s+\$(0x[0-9a-f]+|[0-9]+), %rdx", insn)
        if cmp:
            rhs = int(cmp[1], 0)
            flags = (n == rhs, n < rhs)
        elif re.fullmatch(r"testq\s+%rdx, %rdx", insn):
            flags = (n == 0, False)
        elif op.startswith("j"):
            target = int(re.search(r"0x([0-9a-f]+)", insn)[1], 16)
            if op == "jmp":
                take = True
            else:
                require(flags is not None, f"unknown dispatch flags: {insn}")
                equal, below = flags
                choices = {"je": equal, "jne": not equal, "jb": below,
                           "jae": not below, "jbe": below or equal,
                           "ja": not below and not equal}
                require(op in choices, f"unsupported branch: {insn}")
                take = choices[op]
            if take:
                if op != "jmp":
                    taken_branches += 1
                pc = target
                continue
        require(not op.startswith("call"), f"class {n} calls out: {insn}")
        pc = next_pc[pc]
    raise SystemExit(f"{cpu}: dispatch did not terminate")


def check_medium_bytes(name, n, *, fill=False):
    """Check actual vector offsets, source snapshots, coverage, and access bounds."""
    dst_base = 1 << 20
    scalars = {"%rsi": 0, "%rdi": dst_base, "%rdx": n}
    vectors = {}
    covered = set()
    stored = False

    def address(operand):
        match = re.fullmatch(r"(-?0x[0-9a-f]+)?\((%r\w+)(?:,(%r\w+))?\)", operand)
        require(match is not None, f"{name}/{n}: unknown address {operand}")
        offset, base, index = match.groups()
        return int(offset or "0", 0) + scalars[base] + (scalars[index] if index else 0)

    for line in class_path(name, n).splitlines():
        parts = line.split(None, 1)
        op = parts[0]
        if len(parts) == 1:
            continue
        operands = re.split(r",\s*(?![^()]*\))", parts[1])
        if op == "movq" and len(operands) == 2 and operands[0] in scalars:
            scalars[operands[1]] = scalars[operands[0]]
        elif op == "vpbroadcastb":
            vectors[operands[1]] = None
        elif op == "vmovdqu64":
            source, dest = operands
            reg = dest if dest.startswith("%") else source
            width = 64 if reg.startswith("%zmm") else 32
            if dest.startswith("%"):
                require(not fill and not stored, f"{name}/{n}: load after store")
                offset = address(source)
                require(0 <= offset <= n - width, f"{name}/{n}: source access outside bounds")
                vectors[dest] = offset
            else:
                stored = True
                offset = address(dest) - dst_base
                require(0 <= offset <= n - width, f"{name}/{n}: destination access outside bounds")
                require(source in vectors and vectors[source] == (None if fill else offset),
                        f"{name}/{n}: wrong source bytes")
                covered.update(range(offset, offset + width))
    require(covered == set(range(n)), f"{name}/{n}: incomplete vector coverage")


# LLVM can merge the pair candidate with the identical move entry.
if entry_pairs and "x86_64.move.moveKernel" not in syms:
    require(syms["probe_abi_move"][0] == syms["probe_abi_copy"][0],
            "missing move entry is not an ABI alias")
    syms["x86_64.move.moveKernel"] = syms["x86_64.move.kernel"]

# The probe object contains only fastmem consumers, so every mem* reference is invalid.
require(not re.search(r"(?<![\w.])(?:__)?(?:memcpy|memmove|memset)(?=[+@>\s-]|$)", dis), "memory symbol reference")
wide = cpu != "x86_64_v3"
fixed_max = 256 if wide else 128
for op in ("copy", "move", "set"):
    for n in range(1, fixed_max + 1):
        text = "\n".join(i for _, i in body(f"probe_{op}_{n}"))
        require(not re.search(r"\b(?:call\w*|jmp)\b", text), f"fixed {op}/{n} calls out")
        if wide and n >= 64:
            require("%zmm" in text and "%ymm" not in text, f"fixed {op}/{n} splits a vector")
            require("vzeroupper" in text, f"fixed {op}/{n} lacks vzeroupper")

for name in ("probeRuntimeCopy", "probeRuntimeMove", "probeRuntimeSet"):
    text = "\n".join(i for _, i in body(name))
    require(re.search(r"\b(?:call\w*|j\w+)\b.*<x86_64\.", text), f"{name} lacks a large-path transfer")
require(any("copyLarge" in name for name in syms), "runtime copy specialization missing")

high_regs = wide and variant != "entry"
for op in ("move", "set"):
    actual_high = "%zmm16" in "\n".join(i for _, i in body(f"x86_64.{op}.kernel"))
    require(actual_high == high_regs, f"{op} does not implement requested variant {variant}")
if wide:
    move_entry = "\n".join(i for _, i in body("x86_64.move.kernel"))
    require(("%zmm31" in move_entry) == (variant == "straight_1k"),
            f"move does not implement requested variant {variant}: 1 KiB class")
# Required branch fingerprints distinguish every requested implementation.
if wide and variant != "entry":
    fingerprints = {
        "high_regs": {0: 2, 4: 4, 8: 3, 17: 2, 65: 5, 129: 6},
        "tiered": {0: 4, 4: 3, 8: 2, 17: 3, 65: 3, 129: 4},
        "compact": {0: 3, 4: 2, 8: 2, 17: 2, 65: 3, 129: 4},
    }
    fingerprints["ymm_medium"] = fingerprints["compact"]
    fingerprints["straight_1k"] = fingerprints["compact"]
    fingerprints["medium_first"] = {0: 4, 4: 3, 8: 3, 17: 2, 65: 2, 129: 3}
    expected = fingerprints["medium_first"] if medium_entry else fingerprints[variant]
    if entry_pairs:
        expected = {0: 3, 4: 4, 8: 4, 17: 4, 65: 2, 129: 3}
    if short_scalar:
        expected = {**expected, 17: 2}
    for n, count in expected.items():
        text = class_path("x86_64.move.kernel", n)
        actual = len(re.findall(r"^j(?!mp)\w+", text, re.MULTILINE))
        require(actual == count, f"move/{n} does not implement requested variant {variant}: {actual} branches")
if wide and variant == "medium_first":
    for op in ("move", "set"):
        require(syms[f"x86_64.{op}.kernel"][0] % 64 == 0, f"{op} entry lacks 64-byte alignment")
if wide and variant == "straight_1k":
    for n in (513, 767, 768, 1023, 1024):
        text = class_path("x86_64.move.kernel", n)
        count = 12 if medium_chunks and n <= 768 else 16
        require(f"%zmm{15 + count}" in text and "vzeroupper" not in text, f"move/{n} lacks the {count}-register class")
        require(not re.search(r"%[yz]mm(?:[0-9]|1[0-5])\b", text), f"move/{n} dirties the low vector bank")
        require(len(re.findall(r"vmovdqu64", text)) == 2 * count, f"move/{n} has wrong vector count")
if wide and args.experiment in ("medium_layout", "medium_entry") and cpu == "graniterapids":
    for op in ("move", "set"):
        require(syms[f"x86_64.{op}.kernel"][0] % 16 == 0, f"{op} entry lacks 16-byte alignment")
if cpu == "graniterapids" and args.experiment == "medium_layout":
    for op in ("move", "set"):
        stats = {}
        class_path(f"x86_64.{op}.kernel", 65, stats)
        require(stats["taken_branches"] == 1, f"{op}/65 lacks medium fallthrough")
if short_scalar:
    text = class_path("x86_64.move.kernel", 1)
    require(len(text.splitlines()) == 14, "move/1 lacks the scalar byte path")
if inline_short_first:
    for op in ("Copy",):
        for n, count in ((1, 5), (4, 3), (8, 2), (15, 2)):
            text = class_path(f"probeRuntime{op}", n)
            actual = len(re.findall(r"^j(?!mp)\w+", text, re.MULTILINE))
            require(actual == count, f"inline {op}/{n} has {actual} branches, expected {count}")
    for n, count in ((1, 2), (4, 5), (8, 5), (16, 5), (24, 5), (48, 5)):
        text = class_path("probeRuntimeMove", n)
        actual = len(re.findall(r"^j(?!mp)\w+", text, re.MULTILINE))
        require(actual == count, f"inline Move/{n} has {actual} branches, expected {count}")
# The move-only entry never tests pointer order in its small classes.
# Concrete lengths trace the complete path, including zero and every boundary.
for n in range(65):
    move_stats = {}
    text = class_path("x86_64.move.moveKernel", n, move_stats)
    require(not re.search(r"\b(?:call\w*|push\w*)\b", text), f"small move/{n} is not a leaf")
    require(not tests_pointer_order(text), f"small move/{n} tests pointer order")
    if high_regs:
        if n == 0:
            budget = 8 if medium_entry or variant == "medium_first" else 6
        elif n < 4:
            budget = 16 if medium_entry or variant == "medium_first" else 14
            if zen4_short and n > 1:
                budget += 2
        else:
            budget = 14 if n < 64 else 18
        require(len(text.splitlines()) <= budget, f"small move/{n} exceeds instruction budget")
        require("vzeroupper" not in text, f"small move/{n} needs vector cleanup")
        if 4 <= n < 64 and not medium_entry and variant != "medium_first":
            taken_budget = 2 if n < 8 else 1 if n <= 16 else 2 if n <= 32 else 3
            require(move_stats["taken_branches"] <= taken_budget,
                    f"small move/{n} exceeds taken-branch budget")

# The pairs experiment must not hide extra taken branches behind medium_entry.
if entry_pairs and high_regs:
    for name in ("x86_64.move.kernel", "x86_64.move.moveKernel"):
        for n in range(4, 64):
            stats = {}
            class_path(name, n, stats)
            budget = (1 if n < 8 else 0 if n <= 16 else 1 if n <= 32 else 2) + medium_fallthrough
            require(stats["taken_branches"] <= budget,
                    f"pairs {name}/{n} exceeds taken-branch budget")

if medium_fallthrough and high_regs:
    for name in ("x86_64.move.kernel", "x86_64.move.moveKernel"):
        for n in range(64, 257):
            stats = {}
            class_path(name, n, stats)
            require(stats["taken_branches"] == (0 if n <= 128 else 1),
                    f"{name}/{n}: medium entry lacks fallthrough")

kernel_counts = {}
for op in ("move", "set"):
    name = f"x86_64.{op}.kernel" if high_regs else f"x86_64.{op}.mediumKernel"
    paths = []
    for n in ((64, 65, 128, 129, 256, 257, 511, 512) if wide else (33, 64, 65, 128, 129, 256)):
        text = class_path(name, n)
        narrow_medium = variant == "ymm_medium" and n <= 256
        register = "%zmm" if wide and not narrow_medium else "%ymm"
        require(register in text, f"kernel {op}/{n} lacks {register}")
        if wide:
            forbidden = "%zmm" if narrow_medium else "%ymm"
            require(forbidden not in text, f"kernel {op}/{n} has wrong medium width")
        require(("vzeroupper" not in text) if high_regs else ("vzeroupper" in text),
                f"kernel {op}/{n} has wrong vector cleanup")
        if high_regs:
            require(not re.search(r"%[yz]mm(?:[0-9]|1[0-5])\b", text),
                    f"kernel {op}/{n} dirties the low vector bank")
        if wide and variant in reordered_variants and n in (65, 128, 129, 256):
            branches = len(re.findall(r"^j(?!mp)\w+", text, re.MULTILINE))
            require(branches == ((2 if n <= 128 else 3) if variant == "medium_first" or medium_entry else (3 if n <= 128 else 4)), f"kernel {op}/{n} has excess dispatch")
        paths.append(n)
    if high_regs:
        for n in (33, 63):
            text = class_path(name, n)
            register = "%ymm16" if entry_pairs and op == "move" else "%xmm" if (variant in (*compact_variants, "medium_first") or short_scalar) and op == "move" else "%ymm16"
            require(register in text and "vzeroupper" not in text,
                    f"kernel {op}/{n} lacks clean high registers")
    kernel_counts[op] = paths
    if wide and op == "set" and not high_regs:
        text = "\n".join(i for _, i in body(name))
        require(re.search(r"vmovdqu8.*\{%k", text), "masked memset store missing")

small_counts = {}
for op in ("move", "set"):
    small_counts[op] = {}
    for n in (0, 1, 4, 8, 15, 16, 17, 31, 32):
        text = class_path(f"x86_64.{op}.kernel", n)
        require(not re.search(r"vzeroupper|%[yz]mm|push|pop|%rsp", text), f"small {op}/{n} has vector cleanup or frame")
        lines = text.splitlines()
        stores = [i + 1 for i, line in enumerate(lines)
                  if re.search(r", [^%]*\([^)]*\)$", line)]
        if n in (1, 4, 8, 15):
            budget = {1: 12, 4: 11, 8: 9, 15: 9}[n] if op == "move" else 11
            # Zen schedules the return-register move before the single-byte store.
            if op == "set" and n == 1 and high_regs and cpu in ("znver4", "znver5"):
                budget = 12
            if wide and op == "move" and variant in reordered_variants:
                budget = ({1: 15, 4: 10, 8: 8, 15: 8} if variant == "tiered" else
                          {1: 13, 4: 15, 8: 15, 15: 15})[n]
            if variant == "medium_first" or medium_entry:
                budget += 2
            if entry_pairs and op == "move":
                budget = 14
            if high_regs and op == "set" and variant in reordered_variants:
                # The return-register move precedes the stores. Total work stays unchanged.
                budget = 14 if variant == "medium_first" or medium_entry else 12
                require(len(lines) <= (16 if variant == "medium_first" or medium_entry else 14), f"small set/{n} exceeds total instruction budget")
            require(stores and stores[0] <= budget, f"small {op}/{n} exceeds first-store budget")
        small_counts[op][n] = {"first_store": stores[0] if stores else None, "instructions": len(lines)}
    entry = "\n".join(i for _, i in body(f"x86_64.{op}.kernel"))
    medium = "" if high_regs else "\n".join(i for _, i in body(f"x86_64.{op}.mediumKernel"))
    require(not re.search(r"\b(?:call\w*|push\w*|pop\w*)\b", entry + medium), f"{op} entry is not a leaf")

for op, kernel in (("copy", "move"), ("move", "move"), ("set", "set")):
    code = body(f"probe_abi_{op}")
    kernel_address = syms["x86_64.move.moveKernel" if op == "move" else f"x86_64.{kernel}.kernel"][0]
    if code[0][0] != kernel_address:
        require(len(code) == 1 and code[0][1].startswith("jmp"), f"ABI {op} is not one direct branch")
        require(f"0x{kernel_address:x} " in code[0][1], f"ABI {op} branches elsewhere")

if high_regs:
    for name in ("x86_64.move.kernel", "x86_64.move.moveKernel", "x86_64.set.kernel"):
        fill = ".set." in name
        limit = 1024 if (medium_chunks if fill else variant == "straight_1k") else 512
        for n in range(64, limit + 1):
            check_medium_bytes(name, n, fill=fill)

large_paths = {}
for op, name in (("copy", "x86_64.move.copyLarge"),
                 ("move", "x86_64.move.largeKernel"),
                 ("set", "x86_64.set.largeKernel")):
    require(name in syms, f"{op} large specialization missing")
    text = "\n".join(i for _, i in body(name))
    register = "%zmm" if wide else "%ymm"
    require(register in text, f"{op} large path lacks {register}")
    if wide:
        require("%ymm" not in text, f"{op} large path splits vectors")
    # x86_64_v4 is the untuned AVX-512 row of tuning.zig: no NT and no REP.
    fleet = cpu in ("sapphirerapids", "graniterapids", "znver4", "znver5")
    nt = wide and fleet and (op != "set" or cpu != "znver4")
    helpers = []
    if high_regs and cpu == "sapphirerapids" and op != "set":
        helpers = ["x86_64.move.streamPages", "x86_64.ops.streamCopyPages"]
    elif high_regs and cpu == "znver5" and op == "set":
        helpers = ["x86_64.set.streamGrouped"]
    parent_text = text
    for helper in helpers:
        require(f"<{helper}>" in parent_text, f"{op} NT helper is unreachable: {helper}")
        parent_text = "\n".join(i for _, i in body(helper))
        text += "\n" + parent_text
    require(("vmovntdq" in text) == nt, f"{op} large path has wrong NT policy")
    require(("sfence" in text) == nt, f"{op} large path has wrong NT fence policy")
    rep = "stosb" if op == "set" else "movsb"
    require((rep in text) == (cpu in ("sapphirerapids", "graniterapids")),
            f"{op} large path has wrong REP policy")
    large_paths[op] = {"symbol": name, "vector": register, "nt": nt, "rep": rep in text}
    if cpu in ("znver4", "znver5") and op != "set":
        # Pin the actual length comparisons, not only the presence of an NT loop.
        limits = [int(value, 0) for value in re.findall(
            r"^cmpq\s+\$(0x[0-9a-f]+|[0-9]+), %rdx$", text, re.MULTILINE)
            if int(value, 0) >= 65536]
        expected = [policy["nt_min"]]
        if cpu == "znver5":
            expected.append(65536)
            if op == "move":
                expected.append(65536 if policy["source_64"] else 0xc00001)
        require(limits == expected, f"{op} large thresholds {limits} differ from {expected}")
        large_paths[op]["length_thresholds"] = limits
if high_regs and cpu == "sapphirerapids":
    tile = "\n".join(i for _, i in body("x86_64.ops.streamCopyPages"))
    require(tile.count("vmovntdq") == 8, "SPR NT tile lacks eight stores")
    require(tile.count("prefetcht0") == 8, "SPR NT tile lacks eight prefetches")
    require("0x1000(" in tile and "0x10c0(" in tile, "SPR NT tile lacks its second page")
    require("sfence" not in tile, "SPR NT tile fences each tile")
    require(not re.search(r"vzeroupper|push|pop", tile), "SPR NT tile has frame or cleanup")
if high_regs and cpu == "znver5":
    fill = "\n".join(i for _, i in body("x86_64.set.streamGrouped"))
    require(fill.count("vpbroadcastb") == 1, "Zen5 NT fill must broadcast once")
    require(fill.count("vmovntdq") == 8, "Zen5 NT fill lacks eight stores")
    require(fill.count("sfence") == 1, "Zen5 NT fill must fence once")
    entry = "\n".join(i for _, i in body("x86_64.set.largeKernel"))
    // Zen 5 memset is always temporal (x86h-set48, 2026-09-29): no NT switch.
    require("vmovntdq" not in entry, "Zen5 fill must not use NT stores")
    require(not re.search(r"push|pop|call", entry), "Zen5 temporal fill acquired a frame")
if temporal_set_256 and high_regs:
    code = body("x86_64.set.largeKernel")
    loops = []
    for address, insn in code:
        branch = re.match(r"j\w+\s+0x([0-9a-f]+)", insn)
        if branch and int(branch[1], 16) < address:
            loops.append([i for a, i in code if int(branch[1], 16) <= a <= address])
    require(len(loops) == 1, "Zen5 temporal fill must have one loop")
    loop = loops[0]
    require(sum(i.startswith("vmovdqa64") for i in loop) == 4,
            "Zen5 temporal fill must have four aligned stores")
    require(len(loop) == 7 and any(re.match(r"addq\s+\$0x100,", i) for i in loop),
            "Zen5 temporal fill must advance 256 bytes in seven instructions")
    stores = [re.fullmatch(r"vmovdqa64\s+(%zmm\d+), (-?0x[0-9a-f]+)?\((%r\w+)\)", i)
              for i in loop if i.startswith("vmovdqa64")]
    require(all(stores), "Zen5 temporal fill has an unexpected store address")
    require([int(s[2] or "0", 0) for s in stores] == [0, 64, 128, 192] and
            len({(s[1], s[3]) for s in stores}) == 1,
            "Zen5 temporal fill has wrong offsets or registers")
    cursor = stores[0][3]
    require(re.fullmatch(rf"addq\s+\$0x100, {cursor}", loop[4]) and
            re.fullmatch(rf"cmpq\s+%r\w+, {cursor}", loop[5]) and re.match(r"jb\s", loop[6]),
            "Zen5 temporal fill has wrong loop control")

if cpu == "znver5":
    code = body("x86_64.move.largeKernel")
    check_nt_frame(code)
    transfers = [i for _, i in code if "<x86_64.move.forwardSource>" in i]
    require(len(transfers) >= 2 and all(i.startswith("j") for i in transfers),
            "forwardSource lacks disjoint and overlap tail transfers")
    source = body("x86_64.move.forwardSource")
    text = "\n".join(i for _, i in source)
    require(not re.search(r"vmovnt|sfence|rep\s", text), "forwardSource uses NT or REP")
    loops = []
    for address, insn in source:
        branch = re.match(r"j\w+\s+0x([0-9a-f]+)", insn)
        if branch and int(branch[1], 16) < address:
            loops.append([i for a, i in source if int(branch[1], 16) <= a <= address])
    require(loops, "forwardSource lacks a loop")
    for loop in loops:
        loads = [i for i in loop if re.search(r"\([^)]*\), %[xyz]mm", i)]
        stores = [i for i in loop if re.search(r"%[xyz]mm\d+, .*\(", i)]
        require(loads and stores, "forwardSource loop lacks vector memory operations")
        require(all(re.match(r"vmovaps\s+.*\), %zmm\d+$", i) for i in loads),
                "forwardSource loop lacks aligned full-width loads")
        require(all(re.match(r"vmovups\s+%zmm\d+,", i) for i in stores),
                "forwardSource loop lacks temporal full-width stores")
    large_paths["forward_source"] = {"aligned_loads": True, "nt": False,
                                     "loop_count": len(loops), "tail_transfers": len(transfers)}
if not wide:
    require("%zmm" not in dis, "v3 uses AVX-512")
print(json.dumps({"cpu": cpu, "status": "pass", "fixed_cases": 3 * fixed_max,
                  "kernel_classes": kernel_counts, "abi": "direct alias", "variant": variant,
                  "experiment": args.experiment, "resolved_policy": policy,
                  "large_paths": large_paths, "small_paths": small_counts,
                  "vector": "zmm" if wide else "ymm", "vzeroupper": "inline/large only" if high_regs else "medium/inline/large",
                  "mem_symbol_references": 0}))
