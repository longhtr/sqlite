#!/usr/bin/env python3
"""Compare source VDBE operation-array append traces from one symbolic program."""

from __future__ import annotations

import pathlib
import sys

import bounded_subprocess as subprocess


def output(executable: str, operations: str) -> list[str]:
    result = subprocess.run([executable, operations], text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(
            f"vdbe-builder-differential: worker failed ({result.returncode}): {executable}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return (result.stdout + result.stderr).splitlines()


def mismatch(oracle: list[str], native: list[str]) -> str | None:
    for index in range(max(len(oracle), len(native))):
        left = oracle[index] if index < len(oracle) else "<missing>"
        right = native[index] if index < len(native) else "<missing>"
        if left != right:
            return f"observation {index}: oracle={left!r} native={right!r}"
    return None


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: vdbe_builder_differential.py ORACLE NATIVE OPERATIONS")
    operations = pathlib.Path(sys.argv[3])
    if not operations.is_file() or operations.stat().st_size > 64 * 1024:
        raise SystemExit("vdbe-builder-differential: missing or oversized symbolic operation input")
    oracle = output(sys.argv[1], str(operations))
    native = output(sys.argv[2], str(operations))
    difference = mismatch(oracle, native)
    if difference is not None:
        raise SystemExit(f"vdbe-builder-differential: mismatch at {difference}")
    if len(oracle) != 398:
        raise SystemExit(f"vdbe-builder-differential: expected 398 observations, got {len(oracle)}")

    mutated = native.copy()
    fields = mutated[0].split("\t")
    fields[4] = str(int(fields[4]) + 1)
    mutated[0] = "\t".join(fields)
    if mismatch(oracle, mutated) is None:
        raise SystemExit("vdbe-builder-differential: capacity mutation escaped comparison")
    print(
        "vdbe-builder-differential: 398 statement metadata/column/text-binding/typed-binding/explain-mode/binding/VList/OOM, unpacked-record allocation/decode/OOM, record serial decode/length, foreign-key guards/OOM, Btree usage/lock-mask, control-flow wrapper, virtual-table error import/OOM, bound-value/varmask/OOM, result-column ownership/OOM, connection/statement-metadata, SQL-save/reprepare-swap, subprogram-link, P4 attachment/replacement/VTab/leaf-owner, KeyInfo-reference, creation/linking/OOM, MakeReady/tail-reuse/OOM, compact-list/transfer, access/mutation, append, growth, operand, capacity, label/fixup, "
        "reader/write, virtual-table argument, progress/interrupt, reusable, reached-limit/one-shot/sticky-OOM, "
        "continuation, and mutation-guard observations match"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
