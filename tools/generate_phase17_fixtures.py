#!/usr/bin/env python3
"""Regenerate the historical Phase 17 bounded regression manifest."""

from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests/fixtures/phase17"


def main() -> None:
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else OUT
    out.mkdir(parents=True, exist_ok=True)
    document = {
        "schema_version": 2,
        "name": "phase17-bounded-api-regression",
        "status": "bounded-regression-evidence",
        "completion_claim": False,
        "profile": "linux-core-public-api-v10",
        "canonical_header_assertions": 166,
        "exported_sqlite_symbols": 286,
        "provisional_symbols_exercised": 281,
        "scope": [
            "selected connection, statement, value, blob, utility, callback, extension, virtual-table, backup, and WAL API examples"
        ],
        "warning": "Passing this corpus does not establish complete SQLite API semantics or complete Phase 17.",
        "clients": ["tests/api/phase17_connection_client.c"],
    }
    (out / "manifest.json").write_text(json.dumps(document, indent=2) + "\n")
    print("generate-phase17-fixtures: wrote bounded regression manifest")


if __name__ == "__main__":
    main()
