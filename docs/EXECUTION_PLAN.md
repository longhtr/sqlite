# Complete Port Execution Plan

## Purpose

Define dependency order and subsystem exit criteria. Mutable counts and immediate status belong only to `docs/CURRENT_STATE.md` and `upstream/port-status.json`.

```text
controls/global runtime
├─ VFS/PCache → pager/WAL → B-tree ─┐
└─ VDBE ownership → parser/compiler ├→ integrated engine
                                    └→ built-ins/Zig API → release
```

Every unit follows the evidence states and one-pass cadence in `docs/ENGINEERING_PROCESS.md`.

## Work package 0 — trustworthy controls

Revalidate existing dossiers, downgrade unsupported claims, keep C out of production, enforce bounded workers, and freeze substitute expansion.

**Exit:** no known invalid promotion; synchronized status and reproducible controls.

## Work package 1 — global runtime

Port active internal constants/types, process ownership, allocator/limits/status, mutex modes, initialize/shutdown rollback, and registries.

**Exit:** one global owner with matching lifecycle/failure/concurrency traces.

## Work package 2 — VFS, files, journals, and PCache

Port VFS services, Unix files/locks/mmap/shm, memdb, memory journal, and upper/lower PCache topology/pressure.

**Exit:** one file/cache graph with applicable OOM, short-I/O, full-disk, mmap, fork, and contention evidence on both targets.

## Work package 3 — pager, rollback journal, and WAL

Port pager state/acquisition, rollback write/recovery, savepoints/subjournals, mode/device matrix, WAL index/readers/writers/recovery/checkpoint, and backup/blob interactions.

**Exit:** source state machines own transactions; crash/fault matrices and bidirectional continuation pass.

## Work package 4 — B-tree

Port owners/locks, pages/cells/payload/cursors, freelist/overflow/pointer maps, insert/delete/balance/root operations, transactions/shared cache/schema/integrity/vacuum; retire reconstruction.

**Exit:** incremental SQLite page algorithms are the sole mutation path with graph/cursor/lock/rollback/corruption evidence.

## Work package 5 — VDBE

Consolidate the builder; complete P4/program destruction, `Mem`, records/cursors, sorter/PMA, all canonical execution cases, reset/finalize/reprepare/bindings/frames/functions; retire the handwritten VM.

**Exit:** final compiler programs execute only through the source-corresponding VDBE with ownership/opcode/failure/continuation evidence.

## Work package 6 — parser, compiler, and planner

Complete AST/schema ownership, concrete Lemon actions/recovery/OOM, tokenizer integration, resolver/walker/expression owners, statement families/triggers/FK/windows/CTEs/vtabs, `where*` planning, and final VDBE emission; retire the handwritten frontend.

**Exit:** generated parser/compiler/planner is the sole frontend and native parser/compiler/planner plus independent SQL suites pass.

## Work package 7 — integrated vertical slices

Integrate final owners for open/schema/prepare; DDL/reload; rowid and WITHOUT ROWID mutation; joins/subqueries/CTEs/aggregates/windows/sort/triggers/FK; transactions/WAL/attach/temp/vacuum/analyze/backup/blob/vtabs; and errors/hooks/reprepare/continuation.

**Exit:** one final owner per architecture layer and no production substitute.

## Work package 8 — built-ins and Zig API

Complete scalar/aggregate/window/date/JSON/format/collation/module behavior and planned Zig API domains. Preserve results, lifetimes, callbacks, reentrancy, threading, and failures; replace C variadics with typed arguments and quarantine transitional exports.

**Exit:** all active public responsibilities have complete final Zig owners and lifecycle/fault/concurrency suites pass.

## Work package 9 — release assurance

Run adapted upstream tests, independent SQL suites, fuzzing, reached allocation/VFS faults, physical crash matrices, concurrency/race tests, bidirectional continuation, performance budgets, clean-checkout reproduction, upstream-sync rehearsal, and both target platforms.

**Release:** every charter completion condition passes, production has zero C objects, and no unexplained defect remains.
