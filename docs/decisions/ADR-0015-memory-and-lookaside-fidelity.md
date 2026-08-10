# ADR-0015: Preserve configurable allocator and two-size lookaside

## Status

Accepted for the memory/lookaside foundation.

## Decision

Preserve configured allocator method copying/lifecycle, request rounding, usable size, realloc failure ownership, zero/excessive requests, alignment, statistics, and heap limits. For the pinned `mem1.c` profile, store rounded size in an eight-byte prefix and expose deterministic fault injection.

Preserve per-connection lookaside normalization/caps, allocator-reported expansion, two-size partition, small-before-large choice, heap fallback, statistics, content-preserving reallocation, and busy reconfiguration.

## Consequences

Connection Parse/VDBE OOM propagation and public allocator/configuration remain separate owners. Changes require layout, lifecycle, statistics, limit, fallback, and reached-fault evidence under `docs/TESTING.md`.
