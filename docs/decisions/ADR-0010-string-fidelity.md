# ADR-0010: Preserve SQLite's byte-oriented ASCII case folding

## Status

Accepted for the initial profile.

## Decision

Preserve the 256-entry fold table, nullable ordering, signed byte differences, bounded comparison for zero/negative counts, wrapping eight-bit name hash, and 30-bit lengths. Fold only ASCII `A`–`Z`; bytes `0x80`–`0xff` remain unchanged. Hash key equality uses the shared implementation.

## Consequences

Unicode-aware comparison remains separate. Public API integration requires its own lifecycle/behavior gates; primitive changes require arbitrary-byte differential evidence under `docs/TESTING.md`.
