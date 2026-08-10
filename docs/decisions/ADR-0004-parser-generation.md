# ADR-0004: Lemon tables plus explicit Zig actions

## Status

Accepted for deterministic Lemon metadata and native table execution; action contracts remain scaffolding under ADR-0041.

## Decision

Keep `parse.y`, Lemon, and the pinned template authoritative. Generate deterministic table, symbol, rule, fallback, destructor, and action identities; execute tables natively in Zig; keep the canonical C parser only as an isolated oracle.

Translate semantic actions recognizably into concrete SQLite AST/list/source owners with matching side effects, allocator/sticky-OOM behavior, recovery, resolver/compiler calls, and cleanup. Local value flow, hooks, fake owners, or event capture do not receive integration credit.

## Consequences

Generation and contract ledgers are reproducible inputs, not parser completion. Integration stops on nondeterministic generation, divergent ownership/recovery/OOM/destructor traces, or a surviving parallel handwritten production frontend. Current evidence and result ownership are interpreted through `docs/TESTING.md` and `upstream/port-status.json`.
