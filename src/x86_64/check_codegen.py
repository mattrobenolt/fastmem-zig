"""Reject split vectors and external memory calls in the x86 probes."""
import argparse
import json
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("cpu")
parser.add_argument("variant", choices=("entry", "high_regs", "tiered", "compact", "medium_first", "ymm_medium", "straight_1k"))
parser.add_argument("artifact")
parser.add_argument("--experiment", default="none",
                    choices=("none", "medium_layout", "medium_entry", "small_paths"))
args = parser.parse_args()
cpu, variant, artifact = args.cpu, args.variant, args.artifact
medium_entry = cpu == "graniterapids" and args.experiment == "medium_entry"
short_scalar = cpu == "znver4" and args.experiment == "small_paths"
inline_short_first = cpu == "sapphirerapids" and args.experiment == "small_paths"
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


def body(name):
    start, size = syms[name]
    return [(a, i) for a, i in instructions.items() if start <= a < start + size]


def require(condition, message):
    if not condition:
        raise SystemExit(f"{cpu}: {message}")


def class_path(name, n):
    """Follow the kernel's size dispatch with concrete RDX and unknown pointers."""
    code = body(name)
    next_pc = {a: b for (a, _), (b, _) in zip(code, code[1:])}
    pc = code[0][0]
    flags = None
    visited = []
    for _ in range(100):
        insn = instructions[pc]
        visited.append(insn)
        op = insn.split()[0]
        if op.startswith("ret"):
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
                pc = target
                continue
        require(not op.startswith("call"), f"class {n} calls out: {insn}")
        pc = next_pc[pc]
    raise SystemExit(f"{cpu}: dispatch did not terminate")


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
        require("%zmm31" in text and "vzeroupper" not in text, f"move/{n} lacks the 16-register class")
        require(not re.search(r"%[yz]mm(?:[0-9]|1[0-5])\b", text), f"move/{n} dirties the low vector bank")
        require(len(re.findall(r"vmovdqu64", text)) == 32, f"move/{n} has wrong vector count")
if wide and args.experiment in ("medium_layout", "medium_entry") and cpu == "graniterapids":
    for op in ("move", "set"):
        require(syms[f"x86_64.{op}.kernel"][0] % 16 == 0, f"{op} entry lacks 16-byte alignment")
if inline_short_first:
    for op in ("Copy", "Move"):
        for n, count in ((1, 3), (4, 2), (8, 2), (15, 2)):
            text = class_path(f"probeRuntime{op}", n)
            actual = len(re.findall(r"^j(?!mp)\w+", text, re.MULTILINE))
            require(actual == count, f"inline {op}/{n} has {actual} branches, expected {count}")
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
            register = "%xmm" if (variant in (*compact_variants, "medium_first") or short_scalar) and op == "move" else "%ymm16"
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
    kernel_address = syms[f"x86_64.{kernel}.kernel"][0]
    if code[0][0] != kernel_address:
        require(len(code) == 1 and code[0][1].startswith("jmp"), f"ABI {op} is not one direct branch")
        require(f"0x{kernel_address:x} " in code[0][1], f"ABI {op} branches elsewhere")

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
    nt = wide and (op != "set" or cpu in ("sapphirerapids", "graniterapids"))
    require(("vmovntdq" in text) == nt, f"{op} large path has wrong NT policy")
    require(("sfence" in text) == nt, f"{op} large path has wrong NT fence policy")
    rep = "stosb" if op == "set" else "movsb"
    require((rep in text) == (cpu in ("sapphirerapids", "graniterapids")),
            f"{op} large path has wrong REP policy")
    large_paths[op] = {"symbol": name, "vector": register, "nt": nt, "rep": rep in text}
if not wide:
    require("%zmm" not in dis, "v3 uses AVX-512")
print(json.dumps({"cpu": cpu, "status": "pass", "fixed_cases": 3 * fixed_max,
                  "kernel_classes": kernel_counts, "abi": "direct alias", "variant": variant, "experiment": args.experiment, "large_paths": large_paths, "small_paths": small_counts,
                  "vector": "zmm" if wide else "ymm", "vzeroupper": "inline/large only" if high_regs else "medium/inline/large",
                  "mem_symbol_references": 0}))
