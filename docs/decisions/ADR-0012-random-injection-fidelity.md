# ADR-0012: Separate deterministic PRNG core from entropy and mutex adapters

## Status

Accepted for the pure utility slice.

## Decision

Preserve SQLite's ChaCha20 core, seed layout, counter initialization, reverse buffered consumption, reset, and byte-exact save/restore. Inject entropy into the pure state; process integration separately owns initialization, mutex, buffering, reset/null handling, and selected-VFS entropy.

## Consequences

Call boundaries intentionally affect output order. Final integration requires selected-VFS entropy, short/failure behavior, concurrency, fork, and platform evidence under `docs/TESTING.md`.
