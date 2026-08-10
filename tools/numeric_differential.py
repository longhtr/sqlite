#!/usr/bin/env python3
"""Compare SQLite integer and floating-point numeric parsing traces."""

import random
import bounded_subprocess as subprocess
import sys


def run(worker: str, operations: list[str]) -> bytes:
    return subprocess.run([worker, *operations], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def scenarios() -> list[list[str]]:
    integers = [b"", b"0", b"  +42  ", b"42x", b"9223372036854775807",
                b"9223372036854775808", b"-9223372036854775808",
                b"0xffffffffffffffff", b"4294967296", b"0x80000000"]
    floats = [b"", b".", b"42", b"-0.0", b"  1.25e2  ", b"1e", b"1e+",
              b"1x", b"3500000000000000.2500001", b"1e-400", b"1e400",
              b"2.2250738585072014e-308", b"1.7976931348623157e308"]
    regression = [
        f"1.844674407370955{tail:04d}e{exponent}".encode()
        for exponent in range(-200, 201)
        for tail in (592, 1609)
    ]
    result = [[*(f"i:1:{x.hex()}" for x in integers),
               *(f"s:{x.hex()}" for x in integers),
               *(f"f:{x.hex()}" for x in floats),
               *(f"f:{x.hex()}" for x in regression)]]
    for seed in range(23):
        rng = random.Random(seed)
        operations: list[str] = []
        for _ in range(150):
            value = bytes(rng.choice(b"0123456789abcdefxX+- \t\nZ") for _ in range(rng.randrange(0, 35)))
            operations += ["i:1:" + value.hex(), "s:" + value.hex()]
            text = bytes(rng.choice(b"0123456789+- \tZ") for _ in range(rng.randrange(0, 25)))
            little = b"".join(bytes((byte, rng.randrange(0, 3) == 0)) for byte in text)
            big = b"".join(bytes((rng.randrange(0, 3) == 0, byte)) for byte in text)
            operations += ["i:2:" + little.hex(), "i:3:" + big.hex()]
            floating = bytes(rng.choice(b"0123456789eE.+- \t\nZ") for _ in range(rng.randrange(0, 50)))
            operations.append("f:" + floating.hex())
            digits = "".join(str(rng.randrange(10)) for _ in range(rng.randint(1, 35)))
            point = rng.randrange(len(digits) + 1)
            valid = ("-" if rng.randrange(2) else "") + digits[:point] + "." + digits[point:]
            valid += f"e{rng.randint(-450, 450):+d}"
            operations.append("f:" + valid.encode().hex())
        result.append(operations)
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: numeric_differential.py C_WORKER ZIG_WORKER")
    cases = scenarios()
    for index, operations in enumerate(cases):
        oracle = run(sys.argv[1], operations)
        native = run(sys.argv[2], operations)
        if oracle != native:
            raise SystemExit(
                f"numeric mismatch {index}\n{operations!r}\n"
                f"C={oracle.decode(errors='replace')}\nZ={native.decode(errors='replace')}"
            )
    print(f"numeric-differential: {len(cases)} isolated cases match")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
