"""Check the x86_64 runtime dispatch of a baseline build (docs/runtime-dispatch.md).

Arguments: the baseline codegen probe object, then one triple per level:
LEVEL LEVEL_OBJECT COMPTIME_PROBE_OBJECT.

1. Each C-ABI entry is the stub: one pointer load and one indirect jump.
2. The inline classes stay inline up to 128 bytes; larger sizes jump or call
   through the pointer of the same operation.
3. Every level, resolver, and generic entry is a GLOBAL HIDDEN function.
4. The kernels of each level object are instruction-identical to the kernels
   of the comptime build for the same CPU (src/x86_64/codegen.zig probes).
"""

import json
import re
import subprocess
import sys

INLINE_MAX = 128
FIXED_MAX = 256


def run(*args):
    return subprocess.check_output(args, text=True)


class Object:
    def __init__(self, path):
        self.path = path
        sections = {}
        for line in run("llvm-readelf", "-SW", path).splitlines():
            match = re.match(r"\s*\[\s*(\d+)\]\s+(\S+)", line)
            if match:
                sections[int(match[1])] = match[2]
        self.functions = {}
        self.objects = {}
        self.binding = {}
        for line in run("llvm-readelf", "-sW", path).splitlines():
            fields = line.split()
            if len(fields) != 8 or not fields[0].endswith(":"):
                continue
            _, value, size, kind, bind, vis, index, name = fields
            if kind == "FUNC":
                self.functions[name] = (int(value, 16), int(size))
                self.binding[name] = (bind, vis)
            elif kind == "OBJECT" and index.isdigit():
                self.objects[(sections[int(index)], int(value, 16))] = name
        self.owner = {}
        for name, (start, size) in self.functions.items():
            for address in range(start, start + size):
                # Prefer the exported name for aliases.
                if address not in self.owner or not self.owner[address].startswith(("x86_64.", "move.", "set.")):
                    self.owner[address] = name
        self.lines = {}
        current = None
        for line in run("llvm-objdump", "-dr", "--no-show-raw-insn", path).splitlines():
            header = re.match(r"^([0-9a-f]+) <(.+)>:$", line)
            if header:
                current = int(header[1], 16)
                self.lines.setdefault(current, [])
            elif current is not None and line.strip():
                self.lines[current].append(line)

    def body(self, name):
        start, size = self.functions[name]
        result = []
        for line in self.lines[start]:
            # Relocation lines have the same "offset: text" shape.
            inst = re.match(r"^\s*([0-9a-f]+):\s+(.*)$", line)
            if inst:
                address = int(inst[1], 16)
                if address >= start + size:
                    break
                result.append((address, " ".join(inst[2].split("#")[0].split())))
        return result

    def pointer(self, relocation):
        """Name the object that a PC32 load relocation reads."""
        match = re.fullmatch(r"R_X86_64_PC32 (\S+?)([+-]0x[0-9a-f]+)", relocation)
        if not match:
            return None
        return self.objects.get((match[1], int(match[2], 16) + 4))


def require(condition, message):
    if not condition:
        raise SystemExit(f"x86_64 dispatch: {message}")


def instructions(code):
    return [text for _, text in code if not text.startswith("R_X86_64")]


def transfers(obj, code):
    """Pointer names of every indirect jump or call, and every direct call."""
    loads = {}
    indirect = []
    direct = []
    for (_, text), nxt in zip(code, code[1:] + [(0, "")]):
        load = re.fullmatch(r"movq\s+\(%rip\), (%r\w+)", text)
        if load and nxt[1].startswith("R_X86_64"):
            loads[load[1]] = obj.pointer(nxt[1])
        jump = re.fullmatch(r"(jmpq|callq)\s+\*(%r\w+)", text)
        if jump:
            indirect.append(loads.get(jump[2]))
        if re.match(r"callq?\s+[0-9a-f]", text):
            direct.append(text)
    return indirect, direct


def check_probe(obj):
    evidence = {}
    dis = run("llvm-objdump", "-dr", "--no-show-raw-insn", obj.path)
    require(
        not re.search(r"(?<![\w.])(?:__)?(?:memcpy|memmove|memset)(?=[+@>\s-]|$)", dis),
        "memory symbol reference",
    )
    for op, pointer in (("memcpy", "copy_fn"), ("memmove", "move_fn"), ("memset", "set_fn")):
        stub = f"x86_64.dispatch.{op}"
        code = obj.body(stub)
        text = [t for t in instructions(code) if not t.startswith("nop")]
        require(len(text) == 2, f"{stub} is not two instructions: {text}")
        indirect, direct = transfers(obj, code)
        require(indirect == [f"x86_64.dispatch.{pointer}"] and not direct, f"{stub} does not jump through {pointer}")
        abi = {"memcpy": "copy", "memmove": "move", "memset": "set"}[op]
        require(obj.functions[f"probe_abi_{abi}"][0] == obj.functions[stub][0], f"abi.{op} is not the stub")
        evidence[op] = {"instructions": text, "bytes": obj.functions[stub][1]}
    for op, pointer in (("copy", "copy_fn"), ("move", "move_fn"), ("set", "set_fn")):
        for n in range(1, FIXED_MAX + 1):
            code = obj.body(f"probe_{op}_{n}")
            text = "\n".join(instructions(code))
            indirect, direct = transfers(obj, code)
            require(not direct, f"fixed {op}/{n} has a direct call")
            if n <= INLINE_MAX:
                require(not re.search(r"\b(?:call\w*|jmp\w*)\b", text), f"fixed {op}/{n} calls out")
                require("%ymm" not in text and "%zmm" not in text, f"fixed {op}/{n} uses AVX in a baseline build")
            else:
                require(indirect == [f"x86_64.dispatch.{pointer}"], f"fixed {op}/{n} does not use {pointer}: {indirect}")
        code = obj.body(f"probeRuntime{op.capitalize()}")
        indirect, direct = transfers(obj, code)
        require(indirect == [f"x86_64.dispatch.{pointer}"], f"runtime {op} large path: {indirect}")
    names = [f"fastmem_x86_{level}_{op}" for level in LEVELS for op in ("memmove", "memset", "name")]
    names += [f"fastmem_x86_{kind}_{op}" for kind in ("resolve", "generic") for op in ("memcpy", "memmove", "memset")]
    for name in names:
        require(obj.binding.get(name) == ("GLOBAL", "HIDDEN"), f"{name} is not GLOBAL HIDDEN: {obj.binding.get(name)}")
    for op in ("memcpy", "memmove", "memset"):
        text = "\n".join(instructions(obj.body(f"fastmem_x86_resolve_{op}")))
        require("cpuid" in text and "xgetbv" in text, f"resolver {op} does not read CPUID and XCR0")
    return evidence


def canonical(level, name):
    name = re.sub(rf"^fastmem_x86_{level}_mem(move|set)$", r"\1.kernel", name)
    return name.removeprefix("x86_64.")


def normalized(obj, level, entry):
    """Instruction text of `entry` and every function that it branches to."""
    result = {}
    pending = [entry]
    while pending:
        name = pending.pop()
        key = canonical(level, name)
        if key in result:
            continue
        lines = []
        for _, text in obj.body(name):
            if text.startswith("nop"):
                continue

            def target(match):
                address = int(match[1], 16)
                owner = obj.owner[address]
                if owner != name:
                    pending.append(owner)
                offset = address - obj.functions[owner][0]
                return f"<{canonical(level, owner)}+{offset:#x}>"

            lines.append(re.sub(r"\b(?:0x)?([0-9a-f]+) <[^>]+>", target, text))
        result[key] = lines
    return result


LEVELS = []


def main():
    probe = Object(sys.argv[1])
    triples = sys.argv[2:]
    require(len(triples) % 3 == 0 and triples, "expected LEVEL LEVEL_OBJECT PROBE_OBJECT triples")
    LEVELS.extend(triples[0::3])
    evidence = {"stubs": check_probe(probe), "levels": {}}
    for level, level_path, comptime_path in zip(triples[0::3], triples[1::3], triples[2::3]):
        level_obj = Object(level_path)
        comptime_obj = Object(comptime_path)
        counts = {}
        for op in ("move", "set"):
            got = normalized(level_obj, level, f"fastmem_x86_{level}_mem{op}")
            want = normalized(comptime_obj, level, f"x86_64.{op}.kernel")
            require(got.keys() == want.keys(), f"{level} {op}: functions {sorted(got)} != {sorted(want)}")
            for key in got:
                require(got[key] == want[key], f"{level} {key}: the level object differs from the -Dcpu={level} build")
            counts[op] = {key: len(lines) for key, lines in sorted(got.items())}
        evidence["levels"][level] = counts
    # The comparison is sensitive: two different levels must differ.
    if len(triples) >= 6:
        first = normalized(Object(triples[1]), triples[0], f"fastmem_x86_{triples[0]}_memmove")
        other = normalized(Object(triples[5]), triples[0], "x86_64.move.kernel")
        require(first != other, f"{triples[0]} matches the {triples[3]} probe: the comparison is blind")
    print(json.dumps({"status": "pass", **evidence}))


if __name__ == "__main__":
    main()
