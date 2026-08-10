# ADR-0011: Preserve SQLite's permissive pure UTF primitives

## Status

Accepted for the initial little-endian profile.

## Decision

Preserve SQLite UTF-8 transitions, UTF-8/UTF-16 writers, zero-terminated/bounded/limited readers, character counting, and native UTF-16 byte counting. Retain SQLite-specific malformed/overlong handling and replacement differences rather than strict standard-library decoding.

Allocating `Mem` translation, BOM mutation, and `sqlite3Utf16to8` remain coupled to their allocator/ownership unit.

## Consequences

Do not replace these primitives with strict Unicode decoders. Changes require malformed, overlong, byte-order, full-range, ownership, and differential evidence under `docs/TESTING.md`.
