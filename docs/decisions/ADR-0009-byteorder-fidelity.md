# ADR-0009: Use explicit bytes for four-byte big-endian fields

## Status

Accepted for the initial profile.

## Decision

Read and write SQLite big-endian on-disk integers with explicit byte shifts, independent of host endianness, alignment, and native loads. B-tree and pager aliases share the implementation.

## Consequences

Additional on-disk codecs follow this pattern and require boundary, unaligned, canary, and differential evidence under `docs/TESTING.md`.
