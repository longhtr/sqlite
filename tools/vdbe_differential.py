#!/usr/bin/env python3
"""Compare bounded VDBE scaffold programs under central worker containment."""

import json
import bounded_subprocess as subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASES = tuple(
    program["name"]
    for program in json.loads((ROOT / "tests/fixtures/vdbe/manifest.json").read_text())["programs"]
)


def run(command: list[str]) -> list[str]:
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=True,
    )
    assert result.stdout is not None
    return result.stdout.strip().splitlines()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: vdbe_differential.py ORACLE NATIVE")
    observations = 0
    for case in CASES:
        oracle = run([sys.argv[1], case])
        native = run([sys.argv[2], case])
        if oracle != native:
            raise SystemExit(f"{case} mismatch\noracle={oracle!r}\nnative={native!r}")
        observations += len(oracle)
    print(f"vdbe-differential: {len(CASES)} programs and {observations} row/halt observations match")


if __name__ == "__main__":
    main()
