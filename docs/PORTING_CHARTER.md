# Porting Charter

## Mission

Translate pinned SQLite 3.53.4 into a source-faithful native Zig core. Preserve SQLite’s architecture, algorithms, formats, SQL semantics, state transitions, failures, concurrency, and reliability properties. The product is not a reduced SQLite-like engine, wrapper, hybrid runtime, or C ABI replacement.

## Product boundary

Production engine code and artifacts are Zig-only. C is limited to pinned source, external oracles, fixture generation, and isolated tests. The public product is a Zig-native API; C symbols, varargs, canonical headers, and binary extension transport are excluded, but their underlying SQLite behavior remains required.

## Fidelity

For the selected profile, preserve recognizable source responsibility and decomposition, control/state/integer/encoding behavior, allocation and ownership, cleanup and results, callback/mutex/lock/VFS/durability order, generated parser/bytecode behavior, and promised continuation after errors. Representation changes require explicit evidence. Similar output from a different architecture is insufficient.

## Completion

Complete means:

1. every active source and behavioral responsibility has one justified final Zig owner, generated/folded owner, or no-code disposition;
2. the native tokenizer, Lemon parser/actions, resolver, compiler, planner, VDBE, storage, transactions, VFS, built-ins, and public operations are connected;
3. applicable native upstream, independent SQL/API, fault, crash, fuzz, concurrency, interoperability, and performance suites pass;
4. database, journal, and WAL continuation is bidirectionally compatible with pinned SQLite;
5. production artifacts contain zero C implementation objects;
6. release claims identify the exact source, profile, platform, filesystem, threading, and durability matrix.

A bounded test proves only its named observation.

## Authority

1. This charter and `docs/SCOPE.md`.
2. Pinned source and selected profile.
3. `docs/ENGINEERING_PROCESS.md`.
4. Accepted ADRs.
5. `docs/EXECUTION_PLAN.md`.
6. Historical manifests and tests.
