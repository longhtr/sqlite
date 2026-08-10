# ADR-0007: Preserve Hash list, bucket, and allocation semantics

## Status

Accepted for the initial 64-bit Linux profile.

## Decision

Preserve caller-owned zero-terminated keys/values, ASCII-insensitive hash/equality, one doubly linked iteration list, contiguous bucket groups, linear-search threshold, resize trigger, and malloc soft limit. Bucket allocation failure is benign degradation; element allocation failure leaves the table unchanged; equivalent-key replacement retains allocation behavior and updates the key pointer.

## Consequences

Do not substitute a standard hash map during fidelity. Callers keep retained keys alive. Target allocator changes require renewed structure, ordering, and failure evidence under `docs/TESTING.md`.
