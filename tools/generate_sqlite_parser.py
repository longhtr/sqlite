#!/usr/bin/env python3
"""Regenerate canonical Lemon parser outputs and their deterministic inventory."""

from __future__ import annotations

import os
import pathlib
import shutil
import sys
import tempfile

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-parser-") as temporary:
        work = pathlib.Path(temporary)
        lemon = work / "lemon"
        subprocess.run(
            [
                os.environ.get("CC", "cc"),
                "-std=c99",
                "-O2",
                ROOT / "upstream/sqlite/tool/lemon.c",
                "-o",
                lemon,
            ],
            check=True,
        )
        shutil.copyfile(ROOT / "upstream/sqlite/tool/lempar.c", work / "lempar.c")
        shutil.copyfile(ROOT / "upstream/sqlite/src/parse.y", work / "parse.y")
        subprocess.run(
            [
                lemon,
                "-DSQLITE_ENABLE_MATH_FUNCTIONS",
                "-DSQLITE_ENABLE_PERCENTILE",
                "-DSQLITE_HAVE_ZLIB=1",
                "-DSQLITE_THREADSAFE=1",
                "-q",
                "-S",
                "parse.y",
            ],
            cwd=work,
            check=True,
        )

        destination = ROOT / "generated/parser"
        destination.mkdir(parents=True, exist_ok=True)
        for suffix in ("c", "h", "sql"):
            shutil.copyfile(work / f"parse.{suffix}", destination / f"sqlite_parse.{suffix}")
    subprocess.run([sys.executable, ROOT / "tools/generate_parser_inventory.py"], check=True)


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
