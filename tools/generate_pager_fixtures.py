#!/usr/bin/env python3
"""Generate deterministic bounded read-only pager scaffold fixtures."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "tests/fixtures/pager"
SQLITE_VERSION_NUMBER = 3_053_004


def put16(buffer: bytearray, offset: int, value: int) -> None:
    buffer[offset : offset + 2] = value.to_bytes(2, "big")


def put32(buffer: bytearray, offset: int, value: int) -> None:
    buffer[offset : offset + 4] = value.to_bytes(4, "big")


def empty_database(page_size: int, pages: int = 1) -> bytearray:
    assert page_size in {512, 4096, 65536}
    assert pages >= 1
    database = bytearray(page_size * pages)
    database[0:16] = b"SQLite format 3\0"
    put16(database, 16, 1 if page_size == 65536 else page_size)
    database[18] = 1
    database[19] = 1
    database[20] = 0
    database[21:24] = bytes((64, 32, 32))
    put32(database, 24, 1)
    put32(database, 28, pages)
    put32(database, 40, 1)
    put32(database, 44, 4)
    put32(database, 56, 1)
    put32(database, 92, 1)
    put32(database, 96, SQLITE_VERSION_NUMBER)

    for page_number in range(1, pages + 1):
        header = (page_number - 1) * page_size + (100 if page_number == 1 else 0)
        database[header] = 13  # leaf table b-tree page
        put16(database, header + 1, 0)
        put16(database, header + 3, 0)
        put16(database, header + 5, 0 if page_size == 65536 else page_size)
        database[header + 7] = 0
    return database


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUTPUT
    output.mkdir(parents=True, exist_ok=True)
    fixtures: list[dict[str, object]] = []

    def emit(
        name: str,
        data: bytes,
        expected_code: int,
        expected_page_size: int | None,
        expected_pages: int | None,
        probes: list[int] | None = None,
    ) -> None:
        path = output / name
        path.write_bytes(data)
        fixtures.append(
            {
                "name": name,
                "sha256": sha256(data),
                "size": len(data),
                "expected_code": expected_code,
                "expected_page_size": expected_page_size,
                "expected_pages": expected_pages,
                "page_probes": probes or [],
            }
        )

    emit("empty.db", b"", 0, 4096, 0)
    emit("valid-empty-512.db", empty_database(512), 0, 512, 1, [1, 2])
    emit("valid-empty-4096.db", empty_database(4096), 0, 4096, 1, [1, 2])
    emit("valid-two-page-4096.db", empty_database(4096, 2), 0, 4096, 2, [1, 2, 3])
    emit("valid-empty-65536.db", empty_database(65536), 0, 65536, 1, [1, 2])

    truncated_source = empty_database(4096, 2)
    for index in range(8, 127):
        truncated_source[4096 + index] = (index * 37) & 0xFF
    truncated = truncated_source[: 4096 + 127]
    emit("truncated-second-page.db", truncated, 0, 4096, 2, [1, 2, 3])

    emit("malformed-short-header.db", bytes(99), 26, None, None)

    bad_magic = empty_database(4096)
    bad_magic[0] ^= 0x20
    emit("malformed-magic.db", bad_magic, 26, None, None)

    bad_page_size = empty_database(4096)
    put16(bad_page_size, 16, 1000)
    emit("malformed-page-size.db", bad_page_size, 26, None, None)

    bad_fractions = empty_database(4096)
    bad_fractions[21:24] = bytes((63, 32, 32))
    emit("malformed-payload-fractions.db", bad_fractions, 26, None, None)

    wal_header = empty_database(4096)
    wal_header[18] = 2
    wal_header[19] = 2
    emit("valid-wal-header-without-wal.db", wal_header, 0, 4096, 1, [1, 2])

    manifest = {
        "schema_version": 1,
        "phase": "phase-6-read-only-pager",
        "profile": "sqlite-3.53.4-core-default-threadsafe1-rollback-readonly",
        "generator": "tools/generate_pager_fixtures.py",
        "fixtures": fixtures,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"generate-pager-fixtures: wrote {len(fixtures)} fixtures")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
