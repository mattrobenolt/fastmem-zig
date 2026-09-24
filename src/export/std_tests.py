"""Run selected upstream std tests with fastmem in a private Zig library copy."""
import argparse
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("zig")
    parser.add_argument("zig_lib")
    parser.add_argument("fastmem")
    parser.add_argument("options")
    args = parser.parse_args()
    lib = Path(args.zig_lib).resolve()
    fastmem = Path(args.fastmem).resolve()
    options = Path(args.options).resolve()
    with tempfile.TemporaryDirectory(prefix="fastmem-std-") as temp:
        temp = Path(temp)
        overlay = temp / "lib"
        overlay.mkdir()
        # std/std.zig must be the root. Zig rejects a second module that owns
        # any std file, and an ordinary import does not collect std tests.
        for child in lib.iterdir():
            if child.name == "std":
                shutil.copytree(child, overlay / "std")
            else:
                (overlay / child.name).symlink_to(child)
        root = overlay / "std/std.zig"
        root.chmod(0o644)
        with root.open("a") as f:
            f.write('''
comptime {
    if (@import("builtin").is_test) {
        const fastmem = @import("fastmem");
        fastmem.exportSymbols();
        const addresses = struct {
            const copy = fastmem.abi.memcpy;
            const move = fastmem.abi.memmove;
            const set = fastmem.abi.memset;
        };
        @export(&addresses.copy, .{ .name = "p6_memcpy" });
        @export(&addresses.move, .{ .name = "p6_memmove" });
        @export(&addresses.set, .{ .name = "p6_memset" });
    }
}
''')
        for target, cpu in (("native", "native"), ("x86_64-linux-gnu", "x86_64_v3")):
            for mode in ("ReleaseFast", "ReleaseSafe"):
                binary = temp / f"std-{target}-{mode}"
                cmd = [args.zig, "test", "--zig-lib-dir", str(overlay),
                       "-O", mode, "-target", target, "-mcpu=" + cpu,
                       "--dep", "fastmem", "-Mroot=" + str(root),
                       "-fno-builtin", "-fomit-frame-pointer", "-target", target,
                       "-mcpu=" + cpu, "--dep", "fastmem_options",
                       "-Mfastmem=" + str(fastmem), "-Mfastmem_options=" + str(options),
                       "--test-no-exec", "-femit-bin=" + str(binary)]
                for name in ("mem.test", "fmt.test", "sort.test", "sort.block.test",
                             "array_list.test", "hash_map.test", "Io.Writer.test",
                             "Io.Reader.test", "crypto.blake3.test"):
                    cmd += ["--test-filter", name]
                subprocess.run(cmd, check=True, timeout=300)
                subprocess.run(["python3", str(Path(__file__).with_name("check.py")),
                                "--arch", platform.machine() if target == "native" else "x86_64",
                                "--ecosystem", str(binary)], check=True)
                runner = [] if target == "native" or platform.machine() == "x86_64" else ["qemu-x86_64"]
                run = subprocess.run(runner + [str(binary)], capture_output=True, text=True, timeout=300)
                print(run.stdout + run.stderr, end="", flush=True)
                run.check_returncode()
                result = re.search(r"All \d+ tests passed\.|\d+ passed;.*", run.stderr)
                assert result, "test runner did not report a result"
                for group in ("mem", "fmt", "sort", "array_list", "hash_map", "Io.Writer", "Io.Reader", "crypto.blake3"):
                    assert group + ".test." in run.stderr, (group, "tests not collected")
                print(f"PASS std {target}/{cpu} {mode}: {result[0]}", flush=True)


if __name__ == "__main__":
    main()
