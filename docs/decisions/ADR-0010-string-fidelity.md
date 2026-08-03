# ADR-0010: Preserve SQLite's byte-oriented ASCII case folding

## Status

Accepted for the initial profile.

## Decision

The native string primitives preserve SQLite's 256-entry ASCII case-fold table, nullable ordering, exact signed byte differences, bounded comparison behavior for zero and negative counts, wrapping eight-bit name hash, and 30-bit string length.

Only bytes `A` through `Z` are folded. Bytes from `0x80` through `0xff` remain unchanged; these routines do not perform Unicode case folding. Hash table key equality now calls this shared implementation, matching the upstream dependency on `sqlite3StrICmp`.

The internal implementations exist independently of the transitional C-shaped export surface. This ADR does not claim completion of their Zig-native public responsibilities.

## Evidence

- `zig build test` checks all 256 fold-table entries, null ordering, bounded comparisons, non-ASCII bytes, hash wrapping, and length variants.
- `zig build string-differential` compares 24 boundary and seeded cases against the pinned C implementation, including null pointers, embedded terminators, arbitrary bytes, and signed counts.
- All nine active-profile table, function, and alias entities are mapped in `upstream/symbol-map.json`.

## Consequences

Unicode-aware comparison must remain a separate operation. Public integration requires the Zig API responsibility, lifecycle, and behavioral gates.
