"""Pin the aarch64 instruction bytes, with the V1 hybrid move head restored.

Update GOLDEN only in a commit that deliberately changes kernel bytes.
"""

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
        "copy": (496, "687eb66c4b79b9b512e6454b4bf38301757aa4b7cc94d89825b3d90cf64d0d5d"),
        "move": (192, "fb44ddb4077266857e85ac46639d2a4e142a8ff1e7da83afd06eca6281fb229a"),
    },
    "neoverse_v3": {
        "set": (336, "6a38736588879006b6c9ae1bfc52574b34696143e7e3310538f0075b4e8347b0"),
        "copy": (528, "de9eda141f65d7bf68d91e53ea30c7ec2becb43f092842a55665877bb171089c"),
        "move": (192, "2928e9a9c2d7c03b51cdbc3a6896ccef36faf78ab1167e67b21feea7cfc639ab"),
    },
}
# Copy and set match V1. V2 retains the new NEON move head.
GOLDEN["neoverse_v2"] = {
    **GOLDEN["neoverse_v1"],
    "move": (192, "d83d946a28edb3ee6f8918234a3eb7b05eb9f6e0aad47d05f4f5e045179b1479"),
}


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
            # fastmem_sve_copy_gt64 is a size-0 hidden label inside
            # fastmem_sve_copy (the > 64 byte mid entry used by the inline
            # layer). It adds no instruction bytes; the copy/move entries
            # below cover the bytes it points into.
            if name == prefix + "copy_gt64":
                continue
            op = name.removeprefix(prefix)
            expected_size, expected_hash = GOLDEN[cpu][op]
            assert size == expected_size, (cpu, name, size, expected_size)
            start = sections[index][4] + value
            actual_hash = hashlib.sha256(raw[start:start + size]).hexdigest()
            assert actual_hash == expected_hash, (cpu, name, actual_hash, expected_hash)
            found.add(op)
    assert found == {"copy", "move", "set"}, found
    print(f"PASS {cpu}: all kernel instruction bytes match GOLDEN")


if __name__ == "__main__":
    main()
