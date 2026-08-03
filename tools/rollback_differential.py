#!/usr/bin/env python3
"""Compare bounded rollback write/recovery interoperability across C and Zig."""

from __future__ import annotations

from pathlib import Path
import shutil
import bounded_subprocess as subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "tests/fixtures/rollback/core-4096.db"


def run(command: list[str]) -> str:
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise SystemExit(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return (result.stdout if result.stdout.strip() else result.stderr).strip()


def inspect(oracle: str, path: Path, expected: int) -> None:
    output = run([oracle, "inspect", str(path)])
    wanted = f"inspect\t{expected}\tok"
    if output != wanted:
        raise SystemExit(f"inspect mismatch for {path}: {output!r} != {wanted!r}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: rollback_differential.py ORACLE NATIVE")
    oracle, native = sys.argv[1:]
    observations = 0
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-phase8-") as temporary:
        temp = Path(temporary)

        continuation = temp / "continuation.db"
        shutil.copyfile(SOURCE, continuation)
        run([oracle, "commit", str(continuation), "111"])
        inspect(oracle, continuation, 111)
        observations += 2
        run([native, "commit", str(continuation), "222"])
        inspect(oracle, continuation, 222)
        observations += 2
        if continuation.with_name(continuation.name + "-journal").exists():
            raise SystemExit("native acknowledged commit left a journal")
        observations += 1

        oracle_hot = temp / "oracle-hot.db"
        shutil.copyfile(SOURCE, oracle_hot)
        run([oracle, "hot", str(oracle_hot), "333"])
        oracle_journal = oracle_hot.with_name(oracle_hot.name + "-journal")
        if not oracle_journal.exists():
            raise SystemExit("oracle phase-one crash did not leave a journal")
        observations += 1
        recovered = run([native, "recover", str(oracle_hot), "444"])
        if recovered != "recovered\t0":
            raise SystemExit(f"native recovery mismatch: {recovered!r}")
        inspect(oracle, oracle_hot, 444)
        if oracle_journal.exists():
            raise SystemExit("native hot recovery left an auxiliary journal")
        observations += 3

        native_hot = temp / "native-hot.db"
        shutil.copyfile(SOURCE, native_hot)
        run([native, "hot", str(native_hot), "555"])
        native_journal = native_hot.with_name(native_hot.name + "-journal")
        if not native_journal.exists():
            raise SystemExit("native phase-one crash did not leave a journal")
        observations += 1
        inspect(oracle, native_hot, 0)
        if native_journal.exists():
            raise SystemExit("oracle hot recovery left an auxiliary journal")
        run([oracle, "commit", str(native_hot), "666"])
        run([native, "commit", str(native_hot), "777"])
        inspect(oracle, native_hot, 777)
        observations += 4

    print(f"rollback-differential: {observations} write/recovery/interoperability observations match")


if __name__ == "__main__":
    main()
