#!/usr/bin/env python3
"""Generate deterministic contract-valid bounded cache state sequences."""

from __future__ import annotations

from pathlib import Path
import random
import sys

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "tests/fixtures/pcache/state-sequences.txt"


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUTPUT
    output.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    for sequence in range(16):
        rng = random.Random(0x53514C697465 + sequence)
        known: set[int] = set()
        dirty: set[int] = set()
        lines.append(f"BEGIN {sequence}")
        for key in range(1, 7):
            lines.append(f"F {key}")
            known.add(key)
        for step in range(40):
            operation = rng.randrange(7)
            key = rng.randrange(1, 13)
            if operation == 0:
                lines.append(f"F {key}")
                known.add(key)
            elif operation == 1:
                lines.append(f"D {key}")
                known.add(key)
                dirty.add(key)
            elif operation == 2:
                if dirty:
                    key = rng.choice(sorted(dirty))
                    lines.append(f"C {key}")
                    dirty.remove(key)
                else:
                    lines.append(f"F {key}")
                    known.add(key)
            elif operation == 3:
                if not known:
                    lines.append(f"F {key}")
                    known.add(key)
                old = rng.choice(sorted(known))
                new = 1000 + sequence * 100 + step
                lines.append(f"M {old} {new}")
                known.remove(old)
                known.add(new)
                if old in dirty:
                    dirty.remove(old)
                    dirty.add(new)
            elif operation == 4:
                maximum = rng.randrange(4, 14)
                lines.append(f"T {maximum}")
                known = {item for item in known if item <= maximum}
                dirty.clear()  # workers clean before positive truncation
            else:
                lines.append("A")
                dirty.clear()
        lines.extend(("A", "H", "END"))
    output.write_text("\n".join(lines) + "\n")
    print("generate-pcache-sequences: wrote 16 deterministic sequences")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
