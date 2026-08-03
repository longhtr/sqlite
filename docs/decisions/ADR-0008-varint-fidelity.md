# ADR-0008: Preserve SQLite varint encoding and permissive decoding

## Status

Accepted for the initial profile.

## Decision

The native varint codec preserves SQLite's 1–9 byte encoding, one- and two-byte write fast paths, ninth-byte eight-bit payload rule, 32-bit saturation, and macro fast paths. Decoding remains permissive: non-canonical encodings are accepted and stop at the first clear high bit in bytes zero through seven.

SQLite's mask-interleaved 64-bit decoder exists to accommodate historical RVT compiler behavior. Zig uses the algebraically equivalent byte-wise accumulation while preserving byte read order and termination branches. `sqlite3VarintLen` is translated independently of the encoder and therefore retains its shift-by-seven result of 10 for unsigned values above `0x7fffffffffffffff`.

## Evidence

- `zig build test` covers every encoding-width boundary, known byte encodings, full-`u64` round trips, non-canonical values, 32-bit saturation, and macro paths.
- `zig build varint-differential` compares 24 isolated boundary and seeded cases against the pinned C implementation, including arbitrary nine-byte inputs.
- All 12 in-profile varint functions, macros, and mask constants are mapped in `upstream/symbol-map.json`.

## Consequences

The decoder deliberately does not reject overlong or otherwise non-canonical inputs. Callers must provide nine readable bytes when the preceding bytes do not terminate the encoding, matching the C contract.
