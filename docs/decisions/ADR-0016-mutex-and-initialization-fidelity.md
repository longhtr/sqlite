# ADR-0016: Use profile-native pthread mutexes and an ordered initialization coordinator

## Status

Accepted for the mutex/initialization foundation.

## Decision

The declared compile-time profile is `SQLITE_THREADSAFE=1`. The native abstraction supports its three runtime modes:

- single-thread: core and connection mutexes disabled;
- multi-thread: core mutexes enabled and connection mutexes disabled;
- serialized: both enabled.

The pthread implementation provides dynamic fast and recursive mutexes, stable identities for static IDs 2–13, ownership/depth assertions, nonblocking try semantics, and nullable no-op internal mutexes. The exact `sqlite3_mutex_methods` layout and a copied custom-method adapter are retained.

Global initialization uses an explicit coordinator. Concurrent callers block behind one initializer, recursion from the initializing thread returns without deadlock, failures unwind initialized subsystems, and shutdown runs hooks before memory and mutex teardown. Configuration is rejected while initialized. Ordered hooks represent subsystem boundaries without granting implementation credit. At adoption, PCache, VFS, memdb, and built-in-function hooks were placeholders; PCache and the scoped Linux VFS/memdb owners have since gained atomic-unit evidence, while remaining hooks retain their recorded status.

## Evidence

- Differential traces cover all runtime modes, recursive entry, static identity, contention, copied custom methods, 100 initialization/reconfiguration cycles, and an eight-thread initialization race.
- Native tests run recursive initialization, failed initialization/retry, contention loops, and dynamic-mutex one-shot/sticky OOM sweeps.
- Migration layout tests fix `sqlite3_mutex_methods` at size 72, alignment 8, and pinned offsets.

## Consequences

`THREADSAFE=0` and `THREADSAFE=2` are not claimed profiles. Zig public mutex and initialization integration remains open; later subsystem work fills the ordered initialization hooks.
