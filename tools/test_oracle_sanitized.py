#!/usr/bin/env python3
"""Build and execute the pinned C oracle smoke test under ASan and UBSan."""

from __future__ import annotations

import os
import pathlib

import bounded_subprocess as subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    output = ROOT / ".reference-build/oracle-sanitized"
    output.mkdir(parents=True, exist_ok=True)
    clang = pathlib.Path(os.environ.get("CLANG", "/usr/bin/clang-21"))
    if not clang.is_file() or not os.access(clang, os.X_OK):
        raise SystemExit(f"oracle-sanitized: pinned clang not found: {clang}")
    executable = output / "sqlite3-oracle-sanitized-smoke"
    subprocess.run(
        [
            clang,
            "-std=c99",
            "-O1",
            "-g",
            "-fno-omit-frame-pointer",
            "-fsanitize=address,undefined",
            "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
            "-DSQLITE_ENABLE_PERCENTILE=1",
            "-DSQLITE_HAVE_ZLIB=1",
            "-DSQLITE_THREADSAFE=1",
            f"-I{ROOT / 'include'}",
            ROOT / "reference/c_oracle/sqlite3.c",
            ROOT / "reference/c_oracle/oracle_smoke.c",
            "-lm",
            "-ldl",
            "-o",
            executable,
        ],
        check=True,
        limits=subprocess.TOOL_LIMITS,
    )
    environment = dict(os.environ)
    environment.update(
        ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:strict_string_checks=1",
        UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1",
    )
    subprocess.run(
        [executable],
        check=True,
        env=environment,
        limits=subprocess.SANITIZER_LIMITS,
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
