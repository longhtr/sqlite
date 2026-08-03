# ADR-0005: Independent bounded durability model

## Status

Accepted as bounded simulator/oracle evidence for the DELETE/FULL model; ADR-0041 prohibits extending it as substitute production architecture.

## Decision

Validate source-translated rollback and WAL protocols against an independent durable/volatile store model, named I/O events, crash exploration, mutation tests, and physical-system profiles. Claims are limited to explicit journal/synchronous/device/filesystem combinations. Reduced models provide tests and protocol evidence only; they do not receive subsystem integration credit.

## Evidence

`zig build rollback-differential` captures and validates the pinned oracle's journal-write → journal-sync → database-write → database-sync → journal-delete ordering. `zig build durability-spike` explores every bounded crash prefix and detects curated ordering mutants.

## Stop condition

Storage porting is blocked if the simulator cannot reproduce selected upstream traces or curated ordering mutants survive.
