#!/usr/bin/env python3
"""Validate translation claims or require an explicit checkpoint threshold."""

from __future__ import annotations

import argparse

from port_batch_gate import require_checkpoint_ready, validate


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-threshold",
        action="store_true",
        help="require an active 200-short or 50-substantive promotion batch",
    )
    arguments = parser.parse_args()
    result = require_checkpoint_ready() if arguments.require_threshold else validate()
    print(
        "verify-port-batch: "
        f"status={result['status']}; active={result['active_entries']} "
        f"(short={result['short']}, substantive={result['substantive']}); "
        f"historical-no-credit={result['historical_claims']}; "
        f"checkpoints={result['checkpoints']}"
    )


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
