# Complete Port Execution Plan

## Objective

Complete the source-faithful Zig-native SQLite core defined by the charter. This file sets dependency order and exit criteria; mutable facts live only in `docs/CURRENT_STATE.md` and `upstream/port-status.json`.

## Execution model

Every unit follows admission → translation → internal trace → integration/retirement → assurance → isolated fidelity-closure review. Keep one critical unit active and use the one-pass cadence in `docs/ENGINEERING_PROCESS.md`.

```text
controls and global model
├─ VFS/PCache → pager/WAL → B-tree ─┐
└─ VDBE ownership → parser/compiler ├→ integrated engine
                                    └→ built-ins/API → release
```

## Work package 0 — trustworthy controls

**Work:** semantically revalidate existing dossiers; downgrade unsupported claims; keep C transport out of production; preserve bounded-worker enforcement; establish a reproducible isolated closure-review pass; freeze substitute expansion.

**Exit:** no known invalid promotion, synchronized status, reproducible controls, and one pilot unit accepted or rejected by the isolated closure-review pass.

## Work package 1 — internal model and global runtime

**Source:** internal headers, configuration inputs, `global.c`, `malloc.c`, `mem1.c`, `status.c`, `mutex*.c`, and initialization paths.

**Order:** active constants/types → one process owner → allocator/limits/status → mutex modes → initialize/shutdown rollback and registries → retire duplicates.

**Exit:** one global owner; matching initialization/allocation/mutex/status traces; failure/retry/concurrency evidence; isolated closure review.

## Work package 2 — VFS, files, journals, and PCache

**Source:** `os*.c`, `memdb.c`, `memjournal.c`, `pcache.c`, and `pcache1.c`.

**Order:** VFS registry/services → Unix files/locks/mmap/shm → memdb → memory journal → upper/lower PCache topology and pressure.

**Exit:** one file/cache graph; source lock/callback/I/O order; applicable OOM, short-I/O, full-disk, mmap, fork, and contention evidence on both targets.

## Work package 3 — pager, rollback journal, WAL

**Order:** pager state/acquisition → rollback write/recovery → savepoints/subjournals → mode/device matrix → WAL/index/readers/writers/recovery/checkpoint → backup/blob interactions.

**Exit:** source state machines own transactions; crash/fault matrices and bidirectional file continuation pass.

## Work package 4 — B-tree

**Order:** exact owners/locks → pages/cells/payload/cursors → freelist/overflow/pointer maps → insert/delete/balance/root operations → transactions/shared cache/schema/integrity/vacuum → retire reconstruction.

**Exit:** incremental SQLite page algorithms are the sole mutation path; graph, cursor, lock, rollback, corruption, and continuation evidence pass.

## Work package 5 — VDBE construction and execution

**Order:** consolidate builder → complete P4 and program destruction → complete `Mem` → records/cursors → sorter/PMA → all 190 execution cases in source order → reset/finalize/reprepare/bindings/frames/functions → retire handwritten VM.

**Exit:** compiler programs execute only through the source-corresponding VDBE; ownership, opcode, sorter, failure, callback, and continuation traces pass.

## Work package 6 — parser, compiler, planner

**Order:** complete AST/schema ownership and destruction → concrete Lemon actions/recovery/OOM → tokenizer/Lemon integration → schema/resolver/walker/expression owners → statement families/triggers/FK/windows/CTEs/vtabs → `where*` planning → emit through final VDBE → retire handwritten frontend.

**Exit:** generated parser/compiler/planner is the sole SQL frontend; native parser/compiler/planner, SQL Logic Test, metamorphic, and SQLancer partitions pass.

## Work package 7 — integrated engine

Vertical slices, each using final owners at every layer:

1. open/schema/prepare/finalize/constant select;
2. table/index DDL and reload;
3. rowid and WITHOUT ROWID mutation with indexes/constraints;
4. joins/subqueries/CTEs/aggregates/windows/sort/triggers/FK;
5. transactions/WAL/attach/temp/vacuum/analyze/backup/blob/vtabs;
6. errors, interrupts, hooks, reprepare, schema changes, continuation.

**Exit:** one final owner per architecture layer and no production substitute.

## Stage 6 — complete Zig-native public API

This retained heading identifies the public-API stage used by documentation controls.

## Work package 8 — built-ins and Zig API

Complete scalar/aggregate/window/date/JSON/format/collation/module behavior and the 18 planned Zig API domains. Preserve SQLite results, lifetimes, callbacks, reentrancy, threading, and failure semantics. Replace C variadics with typed arguments; quarantine transitional exports.

**Exit:** all 286 active public responsibilities have complete reviewed Zig owners and API lifecycle/fault/concurrency suites pass.

## Work package 9 — release assurance

Run adapted upstream tests, independent SQL suites, fuzzing, exhaustive reached allocation/VFS faults, physical crash matrices, concurrency/race tests, bidirectional continuation, pinned performance budgets, clean-checkout reproduction, upstream-sync rehearsal, and both release platforms.

**Release:** every charter completion condition passes, every active responsibility has passed isolated fidelity-closure review, production has zero C objects, and no unexplained defect remains.

## Current critical queue

1. Revalidate existing dossier claims and run isolated fidelity-closure review on the corrected limit unit.
2. Complete top-level initialization/refcount evidence through the single lifecycle owner.
3. Port the dependency-closed Table/Index/FKey/Expr/Select/Window/Trigger destruction graph.
4. Complete P4 dispatch, operation/subprogram/frame destruction, and VDBE deletion.
5. Consolidate the VDBE builder behind one source owner.
6. Connect the first concrete generated parser owner and retire its duplicate path.
7. In parallel only where dependencies are closed, finish PCache topology before pager expansion.

The queue changes only when a dependency closes or evidence invalidates it—not to maximize counts.
