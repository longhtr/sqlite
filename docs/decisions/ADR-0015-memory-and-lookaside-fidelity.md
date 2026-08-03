# ADR-0015: Preserve the configurable allocator contract and two-size lookaside

## Status

Accepted for the memory/lookaside foundation.

## Decision

The native memory layer is not a bare `std.mem.Allocator`. It exposes the exact `sqlite3_mem_methods` layout, copies configured method tables, preserves lifecycle callbacks, request rounding, usable-size reporting, realloc ownership on failure, zero/excessive request behavior, eight-byte alignment, memory statistics, and soft/hard heap limits.

The pinned profile delegates storage to libc `malloc`, `realloc`, and `free`, but does not select `HAVE_MALLOC_USABLE_SIZE`. Matching `mem1.c`, the native backend stores the rounded request in an eight-byte prefix and reports that value through `xSize`. A backend interface permits deterministic one-shot and sticky fault injection without changing the contract.

Lookaside remains a per-connection-shaped standalone allocator until native connections exist. It preserves 8-byte slot normalization, the 65,528-byte cap, count overflow cap, allocator-reported expansion, the 128-byte two-size partition, small-before-large selection, heap fallback, statistics, content-preserving reallocation, and busy reconfiguration.

The profile has no dedicated scratch allocator and omits `SQLITE_ENABLE_MEMORY_MANAGEMENT`; deprecated scratch status values remain zero and `sqlite3_release_memory` is a no-op.

## Evidence

- `zig build infrastructure-differential` compares profile allocator sizes/statistics/limits, default and external lookaside layouts, configured-method copying, fallback behavior, and exact return codes.
- Unit tests run bounded one-shot and sticky faults through the manager and lookaside allocator.
- Migration layout tests fix `sqlite3_mem_methods` at size 64, alignment 8, and pinned field offsets.

## Consequences

Connection-specific Parse/VDBE OOM propagation is added with those owners. Zig public allocator/configuration integration remains a public-API task.
