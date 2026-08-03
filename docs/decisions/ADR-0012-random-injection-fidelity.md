# ADR-0012: Separate the deterministic PRNG core from entropy and mutex adapters

## Status

Accepted for the pure utility slice.

## Decision

The native PRNG preserves SQLite's ChaCha20 block function, 44-byte VFS seed layout, counter initialization, reverse buffered-output consumption, reset behavior, and byte-for-byte save/restore state. Entropy is an explicit injectable input to the native state rather than being fetched from a VFS inside the pure utility.

The process integration now owns automatic initialization, a static PRNG mutex, buffered global state, reset/null handling, and the transitional public randomness operation. Entropy currently comes from `getrandom`; routing initialization through the selected VFS `xRandomness` remains pending.

## Evidence

- `zig build test` checks the RFC 8439 block vector, SQLite request-boundary behavior, reset, and state restoration.
- `zig build random-differential` compares 24 seeded operation traces against the pinned C implementation with injected identical entropy, including resets and save/restore.
- `zig build random-process-differential` compares process reset, initialization, buffering, save/restore, and null-output state.
- All thirteen active-profile PRNG entities are reviewed in `upstream/symbol-map.json`.

## Consequences

Call boundaries intentionally affect output ordering exactly as in SQLite; this is not exposed as a conventional streaming ChaCha API. Final fidelity still requires selected-VFS entropy, entropy failure/short-read evidence, concurrent stress/TSAN, fork behavior, and the target matrix.
