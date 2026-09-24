"""Pin the measured aarch64 instruction bytes from revision 2fe71ee."""

import hashlib
import struct
import sys
from pathlib import Path

# These hashes cover the old .text bytes, not disassembly or source text.
# V3's move head includes alignment padding before the shared copy body.
GOLDEN = {
    "generic": {
        "set": (288, "692787b6bd827981bde4e9f7423b92392ff4b727d2f898fa27c2c162fac7d823"),
        "copy": (448, "006648e55dd1a1122d97a713fbbe317308f9ae253ddc93a284bca4dfca13da09"),
        "move": (448, "006648e55dd1a1122d97a713fbbe317308f9ae253ddc93a284bca4dfca13da09"),
    },
    "neoverse_v1": {
        "set": (256, "90f42348d31f9f25412aab25f7feeb3acd6652ffbe1772321525fd4bc253e8a0"),
        "copy": (368, "a2dbcc5bb7355421edcd4b9b38dd7103a893ffa36fe11ac567d0b63744997ae7"),
        "move": (368, "a2dbcc5bb7355421edcd4b9b38dd7103a893ffa36fe11ac567d0b63744997ae7"),
    },
    "neoverse_v3": {
        "set": (336, "99f311e978e6357737dab8076d3a5942df16afd9dcb68a95366af057a63c7db1"),
        "copy": (512, "42b31489d0bf022cbf4a91fdaa6303d313df2d82af4fb0f5ae667ada5433b585"),
        "move": (192, "afe634d9643d28a08c5446fb8d770af2769fbb8c8ba37bb300b08c4e9bf36507"),
    },
}
GOLDEN["neoverse_v2"] = GOLDEN["neoverse_v1"]


def main():
    cpu, binary = sys.argv[1:]
    raw = Path(binary).read_bytes()
    shoff = struct.unpack_from("<Q", raw, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", raw, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", raw, shoff + i * shsize) for i in range(shnum)]
    prefix = "fastmem_advsimd_" if cpu == "generic" else "fastmem_sve_"
    found = set()
    for sec in sections:
        if sec[1] != 2:
            continue
        strings_sec = sections[sec[6]]
        strings = raw[strings_sec[4]:strings_sec[4] + strings_sec[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            name_off, _, _, index, value, size = struct.unpack_from("<IBBHQQ", raw, off)
            name = strings[name_off:].split(b"\0", 1)[0].decode()
            if not name.startswith(prefix):
                continue
            op = name.removeprefix(prefix)
            expected_size, expected_hash = GOLDEN[cpu][op]
            assert size == expected_size, (cpu, name, size, expected_size)
            start = sections[index][4] + value
            actual_hash = hashlib.sha256(raw[start:start + size]).hexdigest()
            assert actual_hash == expected_hash, (cpu, name, actual_hash, expected_hash)
            found.add(op)
    assert found == {"copy", "move", "set"}, found
    print(f"PASS {cpu}: all kernel instruction bytes match 2fe71ee")


if __name__ == "__main__":
    main()
