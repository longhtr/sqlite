# ADR-0016: Use profile-native pthread mutexes and ordered initialization

## Status

Accepted for the mutex/initialization foundation.

## Decision

For `SQLITE_THREADSAFE=1`, preserve runtime single-thread, multi-thread, and serialized modes; dynamic fast/recursive mutexes; stable static identities; ownership/depth assertions; nonblocking try; nullable no-op internal mutexes; and copied configured methods.

Use one initialization coordinator: concurrent callers serialize, same-thread recursion does not deadlock, failures unwind completed layers, shutdown order is explicit, and configuration is rejected while initialized. Hooks represent boundaries but grant no implementation credit.

## Consequences

Other compile-time profiles remain unclaimed. Public mutex/initialization and unfinished subsystem hooks remain separate integration work. Changes require mode, recursion, identity, contention, failure/retry, and concurrency evidence under `docs/TESTING.md`.
