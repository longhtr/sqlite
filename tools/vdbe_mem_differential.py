#!/usr/bin/env python3
"""Compare source-corresponding VDBE numeric and Mem-init primitives."""

import math
import random
import struct
import bounded_subprocess as subprocess
import sys


def bits(value: float) -> int:
    return struct.unpack("=Q", struct.pack("=d", value))[0]


def run(worker: str, operations: list[str]) -> bytes:
    return subprocess.run(
        [worker, *operations], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True
    ).stdout


def scenarios() -> list[list[str]]:
    integers = [-(1 << 63), -(1 << 53), -1, 0, 1, (1 << 53) - 1, 1 << 53, (1 << 63) - 1]
    reals = [
        -math.inf,
        -float(1 << 63),
        math.nextafter(-float(1 << 63), 0.0),
        -4.5,
        -0.0,
        0.0,
        4.0,
        4.5,
        math.nextafter(float(1 << 63), 0.0),
        float(1 << 63),
        math.inf,
    ]
    operations: list[str] = []
    for real in reals:
        encoded = bits(real)
        operations.append(f"t:{encoded:016x}")
        for integer in integers:
            operations.append(f"s:{encoded:016x}:{integer}")
            operations.append(f"c:{integer}:{encoded:016x}")
    for nan_bits in [0x7FF8000000000000, 0xFFF8000000000001, 0x7FF0000000000001]:
        for integer in [-1, 0, 1]:
            operations.append(f"s:{nan_bits:016x}:{integer}")
            operations.append(f"c:{integer}:{nan_bits:016x}")
    mask = (1 << 64) - 1
    for serial_type in range(256):
        operations.append(f"l:{serial_type:x}")
    serial_data = [
        bytes.fromhex("0000000000000000"),
        bytes.fromhex("ffffffffffffffff"),
        bytes.fromhex("8000000000000000"),
        bytes.fromhex("7ff8000000000001"),
        bytes.fromhex("3ff0000000000000"),
        bytes.fromhex("0123456789abcdef"),
    ]
    for serial_type in [*range(21), 63, 127, 128, 129, 0xFFFFFFFF]:
        for data in serial_data:
            operations.append(f"g:{serial_type:x}:{data.hex()}")
    for integer in integers:
        operations.append(f"v:4:{integer & mask:016x}:0:0:")
        operations.append(f"v:20:{integer & mask:016x}:0:0:")
    for real in reals:
        if math.isfinite(real):
            operations.append(f"v:8:{bits(real):016x}:0:0:")
            operations.append(f"a:8:{bits(real):016x}")
    for integer in integers:
        operations.append(f"a:20:{integer & mask:016x}")
    for text in [b"", b"0", b"-17x", b"  +42  ", b"9223372036854775808", b"abc"]:
        operations.append(f"v:2:0000000000000000:1:1:{text.hex()}")
        operations.append(f"v:10:0000000000000000:1:1:{text.hex()}")
        little = b"".join(bytes((byte, 0)) for byte in text)
        big = b"".join(bytes((0, byte)) for byte in text)
        operations.append(f"v:2:0000000000000000:2:1:{little.hex()}")
        operations.append(f"v:2:0000000000000000:3:1:{big.hex()}")
    operations += ["v:1:0000000000000000:0:0:", "v:2:0000000000000000:1:0:3132"]
    for address in [0, 8, 0x12345678ABCDEF00]:
        operations.append(f"n:{address:x}")
    operations += [f"d:{scenario:x}" for scenario in range(5)]
    operations += [f"r:{scenario:x}" for scenario in range(160)]
    for flags in [0, 1, 2, 4, 8, 0x10, 0x20, 0x3F, 0x401, 0xDBF]:
        for db in [0, 8, 0x12345678ABCDEF00]:
            operations.append(f"m:{flags:x}:{db:x}")
    result = [operations]
    for seed in range(23):
        rng = random.Random(seed)
        operations = []
        for _ in range(100):
            raw = rng.getrandbits(64)
            real = struct.unpack("=d", struct.pack("=Q", raw))[0]
            integer = rng.randrange(-(1 << 63), 1 << 63)
            operations.append(f"l:{rng.getrandbits(32):x}")
            operations.append(f"g:{rng.randrange(0, 140):x}:{rng.randbytes(8).hex()}")
            if math.isfinite(real):
                operations.append(f"t:{raw:016x}")
                operations.append(f"v:8:{raw:016x}:0:0:")
                operations.append(f"a:8:{raw:016x}")
            operations.append(f"s:{raw:016x}:{integer}")
            operations.append(f"c:{integer}:{raw:016x}")
            operations.append(f"v:4:{integer & ((1 << 64) - 1):016x}:0:0:")
        for _ in range(40):
            text = bytes(rng.choice(b"0123456789+- xZ") for _ in range(rng.randrange(0, 30)))
            operations.append(f"v:2:0000000000000000:1:1:{text.hex()}")
        result.append(operations)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: vdbe_mem_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for index, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"VDBE Mem mismatch {index}\n"
                f"C={oracle.decode(errors='replace')}\n"
                f"Z={native.decode(errors='replace')}"
            )
    print(f"vdbe-mem-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
