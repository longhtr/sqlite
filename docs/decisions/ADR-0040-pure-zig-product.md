# ADR-0040: Pure-Zig source-faithful product

## Status

Accepted. Supersedes ADR-0002 and the production C ABI portions of ADR-0003 and ADR-0039.

## Context

The earlier plan combined two goals: port SQLite behavior to Zig and replace the C `libsqlite3` ABI. The project owner clarified that only the source-faithful port is the product goal. C ABI compatibility adds vararg shims, canonical exports, extension tables, and linker requirements that do not implement SQLite's engine algorithms.

## Decision

- The released engine and Zig API contain only Zig code and Zig-generated artifacts.
- C is permitted only as pinned source, external oracle, fixture generator, or test harness.
- No C object, including an ABI-only shim, may be linked into production artifacts.
- Every active SQLite behavioral responsibility remains in scope.
- C calling conventions, symbol names, SONAME, `va_list`, canonical headers, and unchanged C extension binaries are not completion requirements.
- Public behavior is exposed through an explicit Zig-native API that preserves results, ownership, state, callbacks, concurrency, and failure semantics.
- An optional C compatibility adapter, if ever built, is a separate project and cannot contribute to core completion.

## Consequences

The production build now installs `libsqlite_zig` with zero C objects and no canonical headers. The old shim and manual extension table are isolated under `tests/legacy_c_abi/` for historical regression evidence. Their behavioral observations still must move to native Zig API tests before the test-only shim can be deleted.
