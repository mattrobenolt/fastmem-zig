"""Pin the recursion audit's scope and branch parser."""

import unittest

from audit import audit_recursion, targets


def symbol(address):
    return address, 16, 2, 2, 1


class AuditTests(unittest.TestCase):
    def test_arbitrary_helper_names(self):
        functions = {
            0x100: ["100: callq 0x200"],
            0x200: ["200: callq 0x300 <mem.replace__anon_1>"],
            0x300: ["300: callq 0x100 <memcpy>"],
        }
        symbols = {"memcpy": symbol(0x100), "common.copySmall": symbol(0x200),
                   "mem.replace__anon_1": symbol(0x300)}
        with self.assertRaisesRegex(AssertionError, "common.copySmall.*mem.replace__anon_1"):
            audit_recursion(functions, symbols, {0x100})

    def test_interior_target(self):
        functions = {0x100: ["100: b 0x204"], 0x200: ["200: nop", "204: bl 0x100"]}
        with self.assertRaisesRegex(AssertionError, "branch to memory entry"):
            audit_recursion(functions, {}, {0x100})

    def test_named_panic_only(self):
        functions = {0x100: ["100: bl 0x200"]}
        symbols = {"debug.FullPanic((function 'defaultPanic')).outOfBounds": symbol(0x200)}
        audit_recursion(functions, symbols, {0x100})
        with self.assertRaisesRegex(AssertionError, "missing direct-target disassembly"):
            audit_recursion(functions, {"debug.notAPanic": symbol(0x200)}, {0x100})

    def test_branch_forms(self):
        lines = ["100: cbnz x0, 0x200", "104: tbnz w1, #3, 0x204",
                 "108: b.eq 0x208", "10c: loop 0x20c", "110: je 0x210 <body>",
                 "114: callq *%rax", "118: br x0", "11c: blr x1"]
        self.assertEqual(targets(lines), [0x200, 0x204, 0x208, 0x20c, 0x210])


if __name__ == "__main__":
    unittest.main()
