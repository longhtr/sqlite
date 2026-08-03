#!/usr/bin/env python3
"""Rename only SQLite's tokenizer definition for the test-only hybrid parser."""

from __future__ import annotations

import pathlib
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_hybrid_parser.py INPUT OUTPUT")
    source = pathlib.Path(sys.argv[1]).read_text()
    needle = "i64 sqlite3GetToken(const unsigned char *z, int *tokenType){"
    if source.count(needle) != 1:
        raise SystemExit("unexpected sqlite3GetToken definition count")
    source = source.replace(
        needle,
        "i64 sqlite3OracleGetToken(const unsigned char *z, int *tokenType){",
    )
    pathlib.Path(sys.argv[2]).write_text(source)


if __name__ == "__main__":
    main()
