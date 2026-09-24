"""Inspect linked ELF symbols and branches, then execute the consumer."""
import argparse
import platform
import re
import struct
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True)
    parser.add_argument("--division", choices=("yes", "no"), required=True)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--shared", action="store_true")
    parser.add_argument("binary")
    args = parser.parse_args()
    binary = args.binary
    raw = open(binary, "rb").read()
    assert raw[:6] == b"\x7fELF\x02\x01", "expected little-endian ELF64"
    shoff = struct.unpack_from("<Q", raw, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", raw, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", raw, shoff + i * shsize) for i in range(shnum)]
    symbols = {}
    dynamic = set()
    for sec in sections:
        if sec[1] not in (2, 11):
            continue
        strings_sec = sections[sec[6]]
        strings = raw[strings_sec[4]:strings_sec[4] + strings_sec[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            name_off, info, other, index, value, size = struct.unpack_from("<IBBHQQ", raw, off)
            name = strings[name_off:].split(b"\0", 1)[0].decode()
            if sec[1] == 11:
                dynamic.add(name)
            else:
                symbols[name] = (value, size, info, other, index)
    entries = set()
    for op in ("memcpy", "memmove", "memset"):
        value, size, info, other, index = symbols[op]
        assert index != 0 and info >> 4 != 2, (op, "undefined or weak")
        # LLD localizes hidden symbols in the final link.
        assert other & 3 == 2 or info >> 4 == 0, (op, "not hidden/local")
        assert op not in dynamic, (op, "leaks into .dynsym")
        ptr, _, _, _, ptr_index = symbols["p6_" + op]
        sec = sections[ptr_index]
        address = struct.unpack_from("<Q", raw, sec[4] + ptr - sec[3])[0]
        # DSO pointer values are carried by R_*_RELATIVE addends.
        if args.shared:
            for rel in sections:
                if rel[1] == 4:
                    for off in range(rel[4], rel[4] + rel[5], rel[9]):
                        place, _, addend = struct.unpack_from("<QQq", raw, off)
                        if place == ptr:
                            address = addend
        assert address == value, (op, "not fastmem.abi", hex(address), hex(value))
        entries.add(value)
    assert ("__udivti3" in symbols) == (args.division == "yes"), "division fixture did not control compiler-rt"
    assert not any(re.fullmatch(r"__(memcpy|memmove|memset)_chk", n) for n in symbols), "unexpected fortified call"
    disasm = output("llvm-objdump", "-d", "--no-show-raw-insn", binary)
    functions = {}
    current = None
    for line in disasm.splitlines():
        match = re.match(r"([0-9a-f]+) <(.+)>:", line)
        if match:
            current = int(match[1], 16)
            functions.setdefault(current, [])
        elif current is not None:
            functions[current].append(line)
    def targets(lines):
        result = []
        for line in lines:
            m = re.search(r"\b(?:callq?|jmpq?|j\w+|bl|b(?:\.\w+)?|cbn?z|tbn?z)\s+.*?(?:0x)?([0-9a-f]+)\s+<", line)
            if m:
                result.append(int(m[1], 16))
        return result
    for op in ("copy", "move", "set"):
        target = symbols["mem" + ("cpy" if op == "copy" else op)][0]
        for prefix in ("p6_", "p6_c_"):
            body = functions[symbols[prefix + op][0]]
            assert target in targets(body), (prefix + op, "does not call fastmem", body)
    # Follow kernel helpers, but not std panic/reporting code for invalid input.
    helpers = {v[0] for k, v in symbols.items() if k.startswith(("x86_64.", "root.", "forward.", "memcpy.", "memmove."))}
    seen = set()
    pending = list(entries)
    while pending:
        addr = pending.pop()
        if addr in seen:
            continue
        seen.add(addr)
        for target in targets(functions.get(addr, [])):
            assert target not in entries, (hex(addr), "branch to memory entry", hex(target))
            if target in helpers:
                pending.append(target)
    if args.run:
        host = {"arm64": "aarch64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
        command = [binary] if host == args.arch else ["qemu-" + args.arch, binary]
        subprocess.run(command, check=True, timeout=120)
    print(f"PASS {binary}: ABI identity, strong/hidden, calls, no recursion, no dynsym" + (", runtime Zig/C" if args.run else ""))


if __name__ == "__main__":
    main()
