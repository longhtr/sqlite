# ADR-0006: Preserve BitVec representation and failure behavior

## Status

Accepted for the initial 64-bit Linux profile.

## Decision

The native BitVec preserves SQLite's one-based indexes, 512-byte object layout, target-derived bitmap/hash/subtree thresholds, open-addressing insertion order, collision-triggered subdivision, and caller-owned clear scratch space.

Hash-to-subtree conversion retains SQLite's failure behavior: scratch allocation failure leaves the hash unchanged; a later child allocation failure may leave a partial subtree and returns out-of-memory. The owner must destroy the object after an error.

## Evidence

- `zig build test` runs direct representation, boundary, clear, sequential-program, and exhaustive one-shot and sticky allocator-failure tests.
- `zig build bitvec-differential` compares 24 isolated deterministic and seeded operation traces against the pinned C implementation, including representation and full-bitset digests.
- All 29 active `bitvec.c` entities have targeted differential evidence.
- The mutable built-in test interpreter matches sequential, random, deliberate-fault, and negative-size modes; debug-only output remains pending final fidelity.
- The relational mappings are recorded in `upstream/symbol-map.json`.

## Consequences

A standard-library dynamic bitset or hash map is not substituted during fidelity. Refactoring requires separate performance, OOM, and differential evidence.
