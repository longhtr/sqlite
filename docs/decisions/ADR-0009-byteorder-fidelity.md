# ADR-0009: Use explicit bytes for four-byte big-endian fields

## Status

Accepted for the initial profile.

## Decision

The native four-byte helpers read and write SQLite's big-endian on-disk integer representation with explicit byte shifts. They do not depend on host endianness, pointer alignment, or native integer loads. The B-tree and pager aliases resolve to the same implementation.

## Evidence

- `zig build test` covers boundary values, known byte sequences, round trips, and unaligned input.
- `zig build byteorder-differential` compares 24 boundary and seeded cases against the pinned C implementation and verifies adjacent canary bytes.
- Both implementation functions and all three in-profile aliases are mapped in `upstream/symbol-map.json`.

## Consequences

The explicit implementation is portable across the declared rollout targets. Additional fixed-width on-disk codecs should follow this pattern and require their own mapping and differential corpus.
