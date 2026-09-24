"""Audit all direct kernel branches except named, non-returning panic handlers."""

import re


INSTRUCTION = re.compile(r"^\s*([0-9a-f]+):\s+([a-z0-9_.]+)\s*(.*?)\s*$")
BRANCH = re.compile(r"callq?|j\w+|loop\w*|xbegin|bl|b(?:\.\w+)?|cbn?z|tbn?z")
PANIC = re.compile(
    r"debug\.(?:defaultPanic|panic(?:Extra)?__anon_\d+|"
    r"FullPanic\(\(function 'defaultPanic'\)\)\."
    r"(?:castToNull|copyLenMismatch|corruptSwitch|divideByZero|exactDivisionRemainder|"
    r"forLenMismatch|inactiveUnionField__anon_\d+|incorrectAlignment|integerOutOfBounds|"
    r"integerOverflow|invalidEnumValue|invalidErrorCode|memcpyAlias|outOfBounds|"
    r"reachedUnreachable|sentinelMismatch__anon_\d+|shiftRhsTooBig|shlOverflow|"
    r"sliceCastLenRemainder|startGreaterThanEnd|unwrapError|unwrapNull))"
)


def split_disassembly(disasm):
    functions = {}
    current = None
    for line in disasm.splitlines():
        match = re.match(r"([0-9a-f]+) <(.+)>:", line)
        if match:
            current = int(match[1], 16)
            functions.setdefault(current, [])
        elif current is not None:
            functions[current].append(line)
    return functions


def targets(lines):
    result = []
    for line in lines:
        inst = INSTRUCTION.match(line)
        if not inst or not BRANCH.fullmatch(inst[2]):
            continue
        operand = inst[3].split("<", 1)[0].strip()
        # x86 indirect calls and jumps use '*'. AArch64 uses br/blr.
        if operand.startswith("*"):
            continue
        target = re.search(r"(?:^|,\s*)(?:0x)?([0-9a-f]+)$", operand)
        assert target, ("unparsed direct branch", line)
        result.append(int(target[1], 16))
    return result


def audit_recursion(functions, symbols, entries):
    names = {v[0]: k for k, v in symbols.items() if v[2] & 15 == 2}
    panic = {v[0] for k, v in symbols.items() if PANIC.fullmatch(k)}
    # Every instruction maps to its complete body. A branch into the middle
    # of a shared assembly body must not escape the audit.
    owners = {}
    for addr, lines in functions.items():
        for line in lines:
            inst = INSTRUCTION.match(line)
            if inst:
                owners[int(inst[1], 16)] = addr
    seen = set()
    pending = [(entry, []) for entry in entries]
    while pending:
        addr, path = pending.pop()
        assert addr in owners, (hex(addr), "missing direct-target disassembly", path)
        owner = owners[addr]
        if owner in seen:
            continue
        seen.add(owner)
        path = path + [names.get(owner, hex(owner))]
        for target in targets(functions[owner]):
            if target in entries:
                chain = " -> ".join(path + [names.get(target, hex(target))])
                raise AssertionError("branch to memory entry: " + chain)
            if target not in panic:
                pending.append((target, path))
