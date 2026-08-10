#!/usr/bin/env python3
"""Run formatting, three-mode regressions, artifact audit, and status reporting."""

from __future__ import annotations

import pathlib

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    zig_files = sorted(
        path
        for directory in ("config", "src", "tests", "reference/hybrid_probe", "tools")
        for path in (ROOT / directory).rglob("*.zig")
    )
    subprocess.run(
        ["zig", "fmt", "--check", ROOT / "build.zig", ROOT / "build.zig.zon", *zig_files],
        cwd=ROOT,
        check=True,
        limits=subprocess.BUILD_LIMITS,
    )
    # compatibility-report owns the Debug aggregate and export audit. Run the
    # other optimization modes separately without repeating those Debug gates.
    for arguments in (
        ["zig", "build", "-j1", "test", "-Doptimize=ReleaseSafe"],
        ["zig", "build", "-j1", "test", "-Doptimize=ReleaseFast"],
        ["zig", "build", "-j1", "compatibility-report"],
    ):
        subprocess.run(arguments, cwd=ROOT, check=True, limits=subprocess.BUILD_LIMITS)


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
