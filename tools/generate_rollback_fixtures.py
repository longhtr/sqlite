#!/usr/bin/env python3
"""Generate deterministic bounded rollback-journal scaffold fixtures."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "tests/fixtures/pager/valid-empty-4096.db"
DEFAULT_OUTPUT = ROOT / "tests/fixtures/rollback"


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUTPUT
    output.mkdir(parents=True, exist_ok=True)
    database = output / "core-4096.db"
    shutil.copyfile(SOURCE, database)
    data = database.read_bytes()
    manifest = {
        "schema_version": 1,
        "phase": "phase-8-rollback-journal-writes",
        "profile": "sqlite-3.53.4-delete-full-4096-sector4096",
        "generator": "tools/generate_rollback_fixtures.py",
        "fixtures": [
            {
                "name": database.name,
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "page_size": 4096,
                "initial_user_version": 0,
                "integrity_check": "ok",
            }
        ],
        "mutation": "fixed-size page-1 user_version and change-counter update",
        "commit_events": [
            "journal_write",
            "journal_initial_sync",
            "journal_header_write",
            "journal_final_sync",
            "database_write",
            "database_sync",
            "journal_delete",
        ],
        "fault_targets": {
            "write_calls": 6,
            "sync_calls": 3,
            "truncate_calls": 2,
            "delete_calls": 1,
            "open_calls": 1,
            "lock_calls": 1,
            "short_write_calls": 1,
            "sticky_targets": ["write", "sync", "delete"],
        },
        "immediate_crash_fault_boundaries": 12,
        "interoperability": [
            "oracle_commit_native_continue_oracle_read",
            "oracle_hot_native_recover_continue",
            "native_hot_oracle_recover_continue",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("generate-rollback-fixtures: wrote 1 core fixture")


if __name__ == "__main__":
    main()
