# ADR-0007: Preserve Hash list, bucket, and allocation semantics

## Status

Accepted for the initial 64-bit Linux profile.

## Decision

The native Hash preserves SQLite's caller-owned zero-terminated keys and values, ASCII-case-insensitive hashing and comparison, single doubly-linked iteration list, contiguous per-bucket list groups, linear-search threshold, resize trigger, and 1,024-byte malloc soft limit.

A bucket-table allocation failure remains a benign performance degradation: the new element is inserted using the existing representation. An element allocation failure returns the proposed value and leaves the table unchanged. Replacement updates the retained key pointer but does not allocate or recompute the equivalent case-insensitive hash.

The initial profile's bucket requests and allocator size classes produce the same effective 15- and 64-bucket sizes as SQLite's `sqlite3MallocSize()` behavior. A target with different allocator size classes requires renewed structural differential evidence.

## Evidence

- `zig build test` runs direct layout, ordering, threshold, replacement, removal, soft-limit, and bounded one-shot and sticky allocation-failure sweeps.
- `zig build hash-differential` compares 24 isolated deterministic and seeded operation traces against the pinned C implementation, including operation results, key replacement, hash values, bucket counts, and final iteration order.
- All 30 `src/hash.c` and `src/hash.h` entities are mapped in `upstream/symbol-map.json`.

## Consequences

A standard-library hash map is not substituted during fidelity. Keys and values remain caller-owned, and callers must keep each retained key alive until replacement, removal, or clear.
