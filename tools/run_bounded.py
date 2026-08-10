#!/usr/bin/env python3
"""Run one build/test command through the central fail-closed process boundary."""

from __future__ import annotations

import argparse

import bounded_subprocess as subprocess

PROFILES = {
    "worker": subprocess.WORKER_LIMITS,
    "tool": subprocess.TOOL_LIMITS,
    "build": subprocess.BUILD_LIMITS,
    "sanitizer": subprocess.SANITIZER_LIMITS,
    "upstream": subprocess.UPSTREAM_TEST_LIMITS,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=sorted(PROFILES), default="worker")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("run_bounded.py: missing command after --")
    subprocess.run(command, check=True, limits=PROFILES[arguments.profile])


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
