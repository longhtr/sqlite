# ADR-0008: Preserve SQLite varint encoding and permissive decoding

## Status

Accepted for the initial profile.

## Decision

Preserve 1–9 byte encoding, write fast paths, ninth-byte payload, 32-bit saturation, macro paths, byte read order, and permissive non-canonical decoding. The algebraically equivalent Zig decoder replaces a historical compiler-workaround expression without changing termination. `sqlite3VarintLen` remains independent and returns 10 above `0x7fffffffffffffff`.

## Consequences

Do not reject overlong encodings. Callers provide nine readable bytes when earlier bytes do not terminate. Codec changes require boundary, arbitrary-byte, and differential evidence under `docs/TESTING.md`.
