# Durability Model

This document records bounded simulator/prototype evidence already implemented. It is not source-fidelity credit or the final mode matrix. Further production implementation follows dependency-closed pager/WAL/VFS source units under `docs/ENGINEERING_PROCESS.md`; the reduced models are not extended as substitute architecture.

## Rollback DELETE/FULL profile

The first modeled profile is rollback journal `DELETE`, `synchronous=FULL`, local filesystem, ordinary sector writes, with no powersafe-overwrite or atomic-write optimization assumed.

Modeled sequence:

1. Original pages enter the volatile journal.
2. Initial journal sync makes page records durable while the header is non-hot.
3. Header write publishes magic and `nRec` to volatile storage.
4. Final journal sync makes rollback durable.
5. Database writes place new pages in volatile storage.
6. Database sync makes new pages durable.
7. Journal deletion is the modeled commit point.
8. Success is returned only after deletion succeeds.

Before deletion, durable hot-journal recovery restores the old transaction; at and after deletion the new transaction survives. Current tests cover named crash prefixes, six write positions, short writes, three sync positions, two truncate positions, journal open/lock/delete faults, recovery faults, and selected immediate-crash combinations.

`zig build rollback-differential` checks oracle/Zig commit, hot recovery, integrity, logical contents, continuation, acknowledged commit, and auxiliary cleanup. This does not cover unnamed filesystems, page/sector combinations, atomic devices, or other journal/synchronous modes.

## WAL FULL profile

The current bounded WAL model names header write/sync, frame header/page writes, WAL sync, index publication, checkpoint database write/sync, and WAL reset. WAL sync is the modeled commit point. Recovery accepts checksum-valid frames only through the last commit mark. Lost index publication is rebuilt from durable WAL. Checkpoint retains authoritative WAL until database pages are durable before reset.

WAL NORMAL/OFF, all page sizes, reader combinations, and the complete WAL-index protocol remain open.

## Required final matrix

The release matrix must enumerate every selected journal mode, synchronous mode, device assumption, page/sector size, filesystem/target, commit point, failure boundary, and acknowledged-commit rule. Each cell needs source-translated native integration, simulator evidence, oracle/Zig differential, and applicable physical process-kill evidence. Every crash child and worker also follows the mandatory resource-containment gate.
