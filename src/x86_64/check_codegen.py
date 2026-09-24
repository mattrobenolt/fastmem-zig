"""Reject split vectors and external memory calls in the x86 probes."""
import json
import re
import subprocess
import sys

cpu, artifact = sys.argv[1:]
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

kernel_counts = {}
for op in ("move", "set"):
    name = f"x86_64.{op}.kernel"
    paths = []
    for n in ((64, 65, 128, 129, 256, 257, 511, 512) if wide else (32, 64, 65, 128, 129, 256)):
        text = class_path(name, n)
        register = "%zmm" if wide else "%ymm"
        require(register in text, f"kernel {op}/{n} lacks {register}")
        if wide:
            require("%ymm" not in text, f"kernel {op}/{n} splits a vector")
        require("vzeroupper" in text, f"kernel {op}/{n} lacks vzeroupper")
        paths.append(n)
    kernel_counts[op] = paths
    if wide and op == "set":
        text = "\n".join(i for _, i in body(name))
        require(re.search(r"vmovdqu8.*\{%k", text), "masked memset store missing")

for op, kernel in (("copy", "move"), ("move", "move"), ("set", "set")):
    code = body(f"probe_abi_{op}")
    kernel_address = syms[f"x86_64.{kernel}.kernel"][0]
    if code[0][0] != kernel_address:
        require(len(code) == 1 and code[0][1].startswith("jmp"), f"ABI {op} is not one direct branch")
        require(f"0x{kernel_address:x} " in code[0][1], f"ABI {op} branches elsewhere")

large = "\n".join(i for name in syms if ".large" in name for _, i in body(name))
if wide:
    require("%zmm" in large and "%ymm" not in large, "large path splits vectors")
    require("vmovntdq" in large and "sfence" in large, "NT store or fence missing")
else:
    require("%zmm" not in dis, "v3 uses AVX-512")
    require("vmovntdq" not in large, "v3 uses NT stores")
if cpu in ("sapphirerapids", "graniterapids"):
    require("movsb" in large and "stosb" in large, "Intel REP paths missing")
else:
    require("movsb" not in large and "stosb" not in large, "unexpected REP path")
print(json.dumps({"cpu": cpu, "status": "pass", "fixed_cases": 3 * fixed_max,
                  "kernel_classes": kernel_counts, "abi": "one direct branch",
                  "vector": "zmm" if wide else "ymm", "vzeroupper": "present",
                  "mem_symbol_references": 0}))
