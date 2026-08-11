# Current State

## Verdict

Incomplete and unsafe for production data. Reusable source-corresponding slices exist, but no complete native SQLite pipeline or Zig-native API exists. Mutable machine accounting is owned by `upstream/port-status.json`; this file contains only verification-checked summary facts and engineering blockers.

## Machine summary

| Fact | Current value |
|---|---:|
| Active source entities | 6,752 active |
| Historical reviewed-or-later classifications | 2,113 |
| Inventoried, unpromoted entities | 0 |
| Unmapped entities | 3,875 |
| Behavioral inventory | 25,930 blocks in 2,457 functions |
| Atomic-unit dossiers total | 47 |
| Admission-ready dossiers | 47 |
| Source-translated atomic units | 15 |
| Historical mechanical function claims | 1,738; 0 completion credit |
| Active batch and durable checkpoints | 0 entries; 0 checkpoints |
| Exact internal layouts | 69 |
| Purposeful tools | 111 purposeful Python scripts |
| Bounded opcode mappings | 107/190; 0 integrated |
| Lemon action contracts | 348/348; 0 integrated |
| Production C objects | 0 |

These are controls and planning facts, not completion percentages.

## Subsystem status

| Area | State | Blocking fact |
|---|---|---|
| Runtime/utilities | partial | Focused traces exist; complete ownership and assurance remain. |
| Parser/compiler/planner | scaffold/missing | Generated tables/contracts do not execute final concrete owners. |
| VDBE/`Mem` | partial | Value conversion, exact numeric rendering, bounded string/blob ownership, bindings, results, and builder/record/P4 lifecycle execute production paths; complete upstream VDBE ownership remains open. |
| Schema/AST | partial | Exact roots exist; recursive ownership/destruction remains incomplete. |
| Process/PCache/VFS/memdb | partial | Shared memdb stores use configured dynamic FAST mutex ownership; new databases use the configured 4,096-byte default page image; ordinary serialization copies the live Pager image page by page; main-schema deserialize stages replacement ownership, preserves old content on allocation failure, publishes transferred bytes before validation, preserves upstream writable-open/READONLY-lock behavior, defers malformed-image failure to first prepare with exact ownership continuation, and retains the external allocation domain across exact resize-OOM continuation. A pinned public-API differential verifies deterministic main and attached-schema copy/deserialize OOM with exact size and old-pointer continuation, image sizing, ownership flags, read-only behavior, malformed continuation, and close results. Memory `ATTACH`/`DETACH` executes through the source-shaped attachment runtime with stable native backends, fixed main/temp catalog indices, duplicate/limit checks, and close ownership. Serialize/deserialize and database metadata now resolve attached private stores with copy/NOCOPY, transfer, deferred malformed-image failure, replacement rejection, and close ownership; schema-qualified table scans and bounded INSERT/UPDATE/DELETE now execute against the selected attached B-tree and match pinned C results; qualified ordinary CREATE/DROP TABLE also targets the attached B-tree and stores unqualified schema SQL; ordinary single- and multi-column CREATE/DROP INDEX, bounded optionally parenthesized unary-plus identity, unary-minus INTEGER, and INTEGER-column constant-add/subtract/multiply/divide, `abs(INTEGER-column)`, and integer-constant `ifnull(column, value)` expression indexes, and bounded whole- or individually-parenthesized one- or two-term `AND`/`OR` combinations of `WHERE column IS [NOT] NULL`, INTEGER-column comparisons/`[NOT] BETWEEN`/two-value `[NOT] IN`, bare/`NOT` INTEGER truth tests, and BINARY/NOCASE/RTRIM-TEXT equality/inequality plus built-in BINARY/NOCASE/RTRIM and registered or UTF-8/UTF-16 factory-resolved application-collated mixed ASC/DESC indexes refill matching existing rows, enforce collation-aware UNIQUE including NULL/conflict rollback, maintain membership-changing INSERT/UPDATE/DELETE and atomically refill named indexes, all indexes of a named table, or registered-collation matches, all ordinary indexes, or the expression-index set through REINDEX and foreign-key action changes inside statement and explicit-transaction savepoints, supplies eligible scalar/composite foreign-key parent keys, reclaims indexes with their table, executes main/attached INDEXED BY scans with pinned-C ordering, and rejects writable incremental-blob opens on indexed or foreign-key child columns while preserving read-only indexed-column opens; same-schema attached foreign keys now enforce inline parent keys and pinned-C delete/update CASCADE, SET NULL, SET DEFAULT, and RESTRICT results, including INTEGER PRIMARY KEY movement and failed-update rollback; public-open connections activate built-in lookup and attached aggregate scans match pinned C; incremental blob handles resolve attached B-trees, preserve read/write bytes, and block DETACH with pinned-C continuation; connection-local virtual tables are keyed by schema, pass attached names to xCreate, allow equal main/attached names, execute qualified scans and drops, and xDisconnect attached instances on DETACH before successful same-name recreation with pinned-source observations; backup handles copy attached source/destination schema names, preserve one snapshot and selected-Pager-size remaining/page-count state across bounded steps, reject retained-source deserialize replacement, restart after intervening source DML and DDL, transfer the selected image with new schema content, preserve values, and retain the source through finish; TEMP tables lazily use a private connection database, normalize CREATE TEMP schema SQL, shadow main/attached tables for unqualified SELECT/INSERT/UPDATE/DELETE/DROP with explicit `temp.` lookup, and own ordinary indexes whose unqualified DROP lookup precedes same-named main/attached indexes; bounded BEGIN/COMMIT/ROLLBACK retains main or attached mutation batches, reports autocommit, rolls back or commits cross-statement writes and CREATE/DROP TABLE, preserves prior work across an immediate-error statement savepoint, and matches failed deferred-FK COMMIT repair plus attached deferred-NO-ACTION continuation; transaction-state and WAL-checkpoint APIs resolve attached names with exact non-WAL and unknown-schema outputs; metadata/file-control APIs target attached schemas and connection-wide cache status/release/flush visits their pagers; configured primary schema names and the permanent `main` alias both resolve in SQL/public lookups; attached triggers, broader expression indexes, broader partial predicates, virtual-table sqlite_schema persistence/reload, broader temporary views/triggers, multi-database atomic commit and broader deferred-FK cases remain open. The process built-in hash has exact pinned-C topology for all 178 active definitions; the two load-extension and nine ALTER records still use explicit erroring internal-registry fallbacks, while remaining deserialize allocation-failure sites and broader ownership remain incomplete. |
| Pager/WAL | scaffold | Rollback-journal transaction/playback and WAL open/checkpoint slices exist, but they do not own the existing SQL storage path. |
| B-tree | partial/scaffold | Reads exist; mutation still reconstructs whole trees. |
| SQL and Zig API | missing | Handwritten bounded frontend remains; active public responsibilities are not complete. |
| Native upstream/assurance | missing | Large upstream partition executes C only; release matrices are absent. |

## Reusable work

Pinned source/profile/toolchain, inventories, generated Lemon/opcode artifacts, the external C oracle, bounded worker/fault/crash/file-interchange infrastructure, exact internal layouts, and selected source-corresponding utility/runtime/storage/VDBE/JSON slices are reusable only through final source owners. The production statement path now snapshots bound values, normalizes native UTF-16 text bindings, rejects oversized `Mem` growth safely, preserves RCStr termination ownership, and destroys rejected API inputs.

## Immediate blockers

1. Open the first dependency-closed net-new production translation batch against the 47 reviewed dossiers; the 1,738 historical mechanical claims are formally retired and retain zero completion credit.
2. Complete global/runtime and recursive AST/schema/VDBE ownership.
3. Connect concrete Lemon/compiler/planner owners and retire the handwritten frontend.
4. Replace reconstructed B-tree mutation and bounded pager/WAL ownership with source algorithms.
5. Complete the Zig-native API and native upstream/assurance matrices.

Dependency order and exit criteria live in `docs/EXECUTION_PLAN.md`; active deltas, quarantined historical claims, and accepted checkpoints live in `upstream/active-port-batch.json`, `upstream/historical-port-claims.json`, and `upstream/port-checkpoints.json`, with their sole prose summary generated through `upstream/port-status.json`.

## Validation

```sh
zig build test -j1
```

This aggregate already owns the control graph; rerunning its constituent targets unchanged is redundant. Passing it is mixed control, atomic, bounded-scaffold, and oracle evidence—not subsystem completion.
