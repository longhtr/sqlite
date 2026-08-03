# ADR-0011: Preserve SQLite's permissive pure UTF primitives

## Status

Accepted for the initial little-endian profile.

## Decision

The native pure UTF slice preserves SQLite's UTF-8 transition table, UTF-8 and UTF-16 character writers, zero-terminated and bounded readers, limited reader, character skipping/counting, and native UTF-16 byte counting.

Malformed UTF-8 handling intentionally remains SQLite-specific. Initial continuation bytes are returned as byte values, overlong encodings of values at least `0x80` are accepted, surrogate and `0xfffe`/`0xffff` results become `0xfffd` in validating readers, and the limited reader performs no replacement. Values outside the Unicode scalar range retain SQLite's byte-level encoding behavior.

`sqlite3VdbeMemTranslate`, BOM mutation, and the allocating `sqlite3Utf16to8` wrapper are not part of this slice. They remain coupled to the future native `Mem` and allocator infrastructure and are not mapped or claimed here.

## Evidence

- `zig build test` covers encoding boundaries, malformed and overlong sequences, replacement differences, both UTF-16 byte orders, surrogate pairs, and character/byte counts.
- `zig build utf-differential` compares 24 boundary and seeded cases against the pinned C implementation using arbitrary UTF-8/UTF-16 bytes and full-range `u32` writer inputs.
- Twelve active-profile pure primitive entities are mapped in `upstream/symbol-map.json`.

## Consequences

These routines must not be replaced with strict standard-library Unicode decoders. The allocating `Mem` translation path requires separate ownership, OOM, BOM, and differential evidence in its later subsystem phase.
