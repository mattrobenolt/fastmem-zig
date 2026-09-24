"""Exercise the runtime gate without a foreign host or executable."""

import unittest
from unittest.mock import patch

import runtime


class RunnerTests(unittest.TestCase):
    def test_non_linux_stays_static_even_with_qemu(self):
        for system in ("Darwin", "Windows"):
            for machine in ("arm64", "x86_64"):
                with patch.object(runtime.platform, "system", return_value=system), \
                     patch.object(runtime.platform, "machine", return_value=machine), \
                     patch.object(runtime.shutil, "which", return_value="/bin/qemu-x86_64") as which:
                    self.assertIsNone(runtime.linux_runner("x86_64"))
                    self.assertIsNone(runtime.linux_runner("aarch64"))
                    which.assert_not_called()

    def test_linux_native(self):
        with patch.object(runtime.platform, "system", return_value="Linux"), \
             patch.object(runtime.platform, "machine", return_value="aarch64"):
            self.assertEqual(runtime.linux_runner("aarch64"), [])

    def test_linux_cross_requires_qemu(self):
        with patch.object(runtime.platform, "system", return_value="Linux"), \
             patch.object(runtime.platform, "machine", return_value="aarch64"), \
             patch.object(runtime.shutil, "which", return_value=None):
            self.assertIsNone(runtime.linux_runner("x86_64"))
        with patch.object(runtime.platform, "system", return_value="Linux"), \
             patch.object(runtime.platform, "machine", return_value="aarch64"), \
             patch.object(runtime.shutil, "which", return_value="/bin/qemu-x86_64"):
            self.assertEqual(runtime.linux_runner("x86_64"), ["/bin/qemu-x86_64"])


if __name__ == "__main__":
    unittest.main()
