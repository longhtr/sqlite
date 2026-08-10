# ADR-0006: Preserve BitVec representation and failure behavior

## Status

Accepted for the initial 64-bit Linux profile.

## Decision

Preserve one-based indexes, the 512-byte object, target-derived bitmap/hash/subtree thresholds, open addressing, collision-triggered subdivision, caller-owned clear scratch space, and SQLite allocation-failure state. Scratch failure leaves the hash unchanged; later child failure may leave a destructible partial subtree and returns out-of-memory.

## Consequences

Do not substitute a generic bitset/hash map during fidelity. Representation changes require renewed structural, differential, and allocation-failure evidence under `docs/TESTING.md`.
