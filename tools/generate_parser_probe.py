#!/usr/bin/env python3
"""Regenerate the deterministic small Lemon parser probe from pinned inputs."""

from __future__ import annotations

import os
import pathlib
import shutil
import tempfile

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-parser-probe-") as temporary:
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
        shutil.copyfile(ROOT / "tests/fixtures/parser_probe.y", work / "parser_probe.y")
        subprocess.run([lemon, "-l", "-q", "-S", "parser_probe.y"], cwd=work, check=True)

        destination = ROOT / "generated/parser"
        destination.mkdir(parents=True, exist_ok=True)
        for suffix in ("c", "h", "sql"):
            shutil.copyfile(work / f"parser_probe.{suffix}", destination / f"parser_probe.{suffix}")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
