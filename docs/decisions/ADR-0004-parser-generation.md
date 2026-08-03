# ADR-0004: Lemon tables plus explicit Zig actions

## Status

Accepted for deterministic Lemon metadata and native table execution; action-contract progress is reclassified as scaffolding by ADR-0041.

## Decision

Keep `parse.y`, Lemon, and the pinned template authoritative. Generate deterministic table, symbol, rule, fallback, destructor, and action identities. Execute the tables natively in Zig. Keep the canonical C parser only as an isolated oracle.

Translate each semantic action recognizably, but do not grant implementation or integration credit to local value flow, hooks, fake owners, or event capture. Concrete SQLite AST/list/source owners, side effects, allocator/sticky-OOM behavior, error recovery, resolver/compiler calls, and cleanup must pass the atomic-unit gates in `docs/ENGINEERING_PROCESS.md`.

## Evidence

- Clean generation inventories 600 states, 412 rules, 322 symbols, and 348 generated semantic-action identities.
- The Zig machine executes canonical tables with the exact generated minor-value union and 50 destructor routes.
- All 348 action IDs have typed local value flow and owner contracts.
- Recognition, finalization, destructor routing, representative action families, and focused Debug/Release tests pass.

This evidence is parser scaffolding. SQL execution still uses the bounded handwritten frontend, and concrete source action owners plus parser-to-resolver/compiler execution are absent.

## Stop condition

Parser integration is blocked if generation ceases to be deterministic, action ownership cannot remain source-recognizable, concrete side effects differ, error/OOM/destructor traces diverge, or a parallel handwritten grammar/frontend remains the production owner after integration.
