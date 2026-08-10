#!/usr/bin/env python3
"""Generate deterministic bounded read-only B-tree scaffold fixtures."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import sys

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "tests/fixtures/btree"
PINNED_SQLITE_VERSION_NUMBER = 3_053_004


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def create_fixture(path: Path, page_size: int, encoding: str, auto_vacuum: str, rows: int) -> None:
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.execute(f"PRAGMA page_size={page_size}")
    db.execute(f"PRAGMA auto_vacuum={auto_vacuum}")
    db.execute(f"PRAGMA encoding='{encoding}'")
    db.execute("PRAGMA journal_mode=OFF")
    db.execute("PRAGMA synchronous=OFF")
    db.execute("PRAGMA secure_delete=ON")
    db.execute("VACUUM")
    db.executescript(
        """
        CREATE TABLE items(
          id INTEGER PRIMARY KEY,
          i INTEGER,
          r REAL,
          t TEXT,
          b BLOB,
          z
        );
        CREATE INDEX items_t_i ON items(t, i);
        CREATE TABLE wr(
          k TEXT,
          n INTEGER,
          v BLOB,
          PRIMARY KEY(k, n)
        ) WITHOUT ROWID;
        """
    )
    item_rows = []
    for i in range(1, rows + 1):
        signed = -i if i % 7 == 0 else i * 17
        real = i + 0.25 if i % 9 else -i / 3.0
        text = f"key-{i:05d}-" + ("λ" if i % 11 == 0 else "x")
        blob = bytes(((i + j * 29) & 0xFF) for j in range(i % 23))
        nullable = None if i % 5 == 0 else (0 if i % 2 else 1)
        item_rows.append((i, signed, real, text, blob, nullable))
    db.executemany("INSERT INTO items VALUES(?,?,?,?,?,?)", item_rows)
    overflow_text = "overflow-λ-" + "abcdefghijklmnopqrstuvwxyz" * 420
    overflow_blob = bytes((i * 37) & 0xFF for i in range(12_000))
    db.execute(
        "INSERT INTO items VALUES(?,?,?,?,?,?)",
        (1 << 40, -(1 << 47), 1.0 / 3.0, overflow_text, overflow_blob, None),
    )
    wr_rows = [
        (f"group-{i % 17:02d}", i, bytes(((i * 3 + j) & 0xFF) for j in range(i % 31)))
        for i in range(1, min(rows, 700) + 1)
    ]
    db.executemany("INSERT INTO wr VALUES(?,?,?)", wr_rows)
    # Exercise schema churn, deletion, freelist population, and page reuse
    # without leaving an extra logical tree in the final workload.
    db.execute("CREATE TABLE churn(x BLOB)")
    db.executemany("INSERT INTO churn VALUES(?)", [(bytes([i & 0xFF]) * 3000,) for i in range(40)])
    db.execute("DROP TABLE churn")
    db.execute("CREATE TABLE reuse_marker(x INTEGER)")
    db.executemany("INSERT INTO reuse_marker VALUES(?)", [(1,), (2,), (3,)])
    db.execute("DROP TABLE reuse_marker")
    if auto_vacuum != "NONE":
        db.execute("PRAGMA incremental_vacuum(2)")
    db.commit()
    db.execute("PRAGMA optimize")
    db.close()

    # SQLite stores the writer library version at bytes 96..99. Normalize it
    # to the pinned oracle so fixture regeneration does not depend on Python's
    # host SQLite patch release.
    data = bytearray(path.read_bytes())
    data[96:100] = PINNED_SQLITE_VERSION_NUMBER.to_bytes(4, "big")
    path.write_bytes(data)


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUTPUT
    output.mkdir(parents=True, exist_ok=True)
    for stale in output.glob("*.db"):
        stale.unlink()
    specs = [
        ("core-512.db", 512, "UTF-8", "NONE", 700),
        ("utf16le-1024.db", 1024, "UTF-16le", "NONE", 500),
        ("utf16be-2048.db", 2048, "UTF-16be", "NONE", 700),
        ("autovacuum-4096.db", 4096, "UTF-8", "INCREMENTAL", 900),
        ("autovacuum-full-8192.db", 8192, "UTF-8", "FULL", 1000),
        ("core-16384.db", 16384, "UTF-8", "NONE", 1400),
        ("core-32768.db", 32768, "UTF-8", "NONE", 1800),
        ("wide-65536.db", 65536, "UTF-8", "NONE", 2600),
    ]
    fixtures = []
    for name, page_size, encoding, auto_vacuum, rows in specs:
        path = output / name
        create_fixture(path, page_size, encoding, auto_vacuum, rows)
        data = path.read_bytes()
        db = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
        roots = {
            name: root
            for name, root in db.execute(
                "SELECT name,rootpage FROM sqlite_schema "
                "WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        freelist_pages = db.execute("PRAGMA freelist_count").fetchone()[0]
        integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
        db.close()
        fixtures.append(
            {
                "name": name,
                "sha256": sha256(data),
                "size": len(data),
                "page_size": page_size,
                "encoding": encoding.lower(),
                "auto_vacuum": auto_vacuum.lower(),
                "freelist_pages": freelist_pages,
                "integrity_check": integrity,
                "rows": rows + 1,
                "roots": roots,
                "seek_rowids": [1, rows // 2, rows, 1 << 40],
                "overflow_rowid": 1 << 40,
            }
        )
    manifest = {
        "schema_version": 1,
        "phase": "phase-7-read-only-btree-records",
        "profile": "sqlite-3.53.4-core-default-threadsafe1-rollback-readonly-binary-collation",
        "generator": "tools/generate_btree_fixtures.py",
        "fixtures": fixtures,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"generate-btree-fixtures: wrote {len(fixtures)} fixtures")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
