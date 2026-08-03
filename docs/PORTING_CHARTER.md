# Porting Charter

## Mission

Translate the pinned SQLite 3.53.4 core into a **source-faithful native Zig port**. Preserve SQLite’s architecture, algorithms, formats, SQL semantics, state transitions, failure behavior, and reliability properties.

The product is not a reduced SQLite-like engine, a wrapper, a hybrid runtime, or a C ABI replacement.

## Product boundary

Production engine code and artifacts are Zig-only. C is allowed only as pinned source, an external oracle, a fixture generator, or isolated diagnostic/test infrastructure. C may never provide missing product behavior.

The public product is a Zig-native API. C symbols, varargs, `va_list`, SONAME, canonical headers, and binary extension-table transport are not requirements; the SQLite behavior behind them remains required.

## Internal fidelity

For the selected profile, preserve:

- source responsibility and recognizable function/state decomposition;
- control, state, integer, encoding, allocation, ownership, result, and cleanup behavior;
- callback, mutex, lock, reentrancy, VFS, and durability order;
- generated parser/bytecode behavior and promised continuation after errors.

Representations may differ only when documented and evidenced. Output compatibility implemented by a different architecture is insufficient.

## Completion

Complete means all of the following:

1. Every active source and behavioral responsibility has an Zig mapping that passed an isolated fidelity-closure review, generated owner, folded owner, or justified no-code disposition.
2. Native tokenizer, Lemon parser/actions, resolver, compiler, planner, VDBE, storage, transactions, VFS, built-ins, and public operations are complete and connected.
3. Applicable native upstream, independent SQL/API, fault, crash, fuzz, concurrency, interoperability, and performance suites pass.
4. Database, journal, and WAL continuation is bidirectionally compatible with pinned SQLite.
5. Production artifacts contain zero C implementation objects.
6. Release claims identify the exact source, profile, platform, filesystem, threading, and durability matrix.

A bounded test proves only its named observation.

## Work rules

- Work in dependency-closed atomic source units.
- Review complete source context before translation.
- Preserve behavior first; refactor later.
- Promote only through source translation, internal trace equivalence, integration, assurance, and an isolated adversarial closure review.
- Treat layouts, hooks, declarations, counts, and bounded substitutes as scaffolding.
- Stop on unexplained mismatch, corruption, race, hang, resource failure, or safety defect.
- Spend normal execution primarily on source analysis, translation, integration, and targeted evidence; batch accounting and documentation at state transitions.

## Authority

1. This charter and `docs/SCOPE.md`.
2. Pinned source and selected profile.
3. `docs/ENGINEERING_PROCESS.md`.
4. Accepted ADRs.
5. `docs/EXECUTION_PLAN.md`.
6. Historical manifests and tests.
