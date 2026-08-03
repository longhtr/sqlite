#!/usr/bin/env python3
"""Compile C layout facts for the native target and compare committed evidence."""

from __future__ import annotations

import json
import pathlib
import platform
import shutil
import bounded_subprocess as subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    machine = platform.machine().lower()
    aliases = {"arm64": "aarch64", "amd64": "x86_64"}
    machine = aliases.get(machine, machine)
    if platform.system() != "Linux":
        raise SystemExit("verify-abi-layout: no committed native profile for this OS")
    expected_path = ROOT / f"generated/abi/{machine}-linux-gnu.json"
    if not expected_path.is_file():
        raise SystemExit(f"verify-abi-layout: missing profile {expected_path.name}")
    compiler = shutil.which("cc")
    if compiler is None:
        raise SystemExit("verify-abi-layout: C compiler not found")
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-layout-") as temp:
        executable = pathlib.Path(temp) / "layout-facts"
        subprocess.run([
            compiler,
            "-std=c11",
            f"-I{ROOT / 'include'}",
            str(ROOT / "tests/abi/layout_facts.c"),
            "-o",
            str(executable),
        ], check=True)
        actual = json.loads(subprocess.check_output([str(executable)], text=True))
    expected = json.loads(expected_path.read_text())
    if actual != expected:
        raise SystemExit(
            "verify-abi-layout: native C layout drift\n"
            f"expected={json.dumps(expected, sort_keys=True)}\n"
            f"actual={json.dumps(actual, sort_keys=True)}"
        )
    print(f"verify-abi-layout: {len(actual)} public layouts match {expected_path.name}")


if __name__ == "__main__":
    main()
