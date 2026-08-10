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
| Process/PCache/VFS/memdb | partial | Shared memdb stores use configured dynamic FAST mutex ownership; new databases use the configured 4,096-byte default page image; ordinary serialization copies the live Pager image page by page; main-schema deserialize stages replacement ownership, preserves old content on allocation failure, publishes transferred bytes before validation, preserves upstream writable-open/READONLY-lock behavior, defers malformed-image failure to first prepare with exact ownership continuation, and retains the external allocation domain across exact resize-OOM continuation. A pinned public-API differential verifies deterministic main and attached-schema copy/deserialize OOM with exact size and old-pointer continuation, image sizing, ownership flags, read-only behavior, malformed continuation, and close results. Memory `ATTACH`/`DETACH` executes through the source-shaped attachment runtime with stable native backends, fixed main/temp catalog indices, duplicate/limit checks, and close ownership. Serialize/deserialize and database metadata now resolve attached private stores with copy/NOCOPY, transfer, deferred malformed-image failure, replacement rejection, and close ownership; schema-qualified read-only table scans now execute against the selected attached B-tree and match pinned C query results; schema-qualified mutation routing remains open. The process built-in hash has exact pinned-C topology for 167 of 178 active definitions; load-extension, ALTER registration, remaining deserialize allocation-failure sites, and broader ownership remain incomplete. |
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
