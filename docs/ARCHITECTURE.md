# Architecture

## Final pipeline

```text
SQL → tokenizer → Lemon parser/actions → resolver/compiler/planner
    → VDBE bytecode/runtime/sorters/cursors
    → B-tree → pager/journal/WAL/PCache → VFS → OS
```

The Zig port preserves this decomposition, algorithms, state machines, and protocol order. Modules may split for maintainability, but every source responsibility retains a traceable owner.

## Boundaries

- Production code and artifacts are Zig-only.
- The public API is Zig-native and preserves SQLite behavior, results, ownership, callbacks, threading, and failure semantics.
- C runs only as isolated source/oracle/test infrastructure.
- Private C state never crosses an oracle protocol.
- Exactly one production owner exists for each state object.
- Generated tables derive reproducibly from pinned inputs.

## Current deviations

Frozen substitutes remain useful only as migration evidence:

- `sql_frontend.zig` is a bounded handwritten frontend;
- generated Lemon tables/action contracts lack concrete final owners;
- `vdbe.zig` is a handwritten runtime with only a bounded subset of opcode-name mappings;
- B-tree mutation reconstructs whole trees;
- pager/WAL models cover selected slices;
- the root API remains transitional and C-shaped.

These implementations may supply fixtures and diagnostics but may not be expanded into the final architecture. A source translation integrates atomically and retires its duplicate.

## Immediate convergence

1. Complete global/runtime ownership.
2. Complete AST/schema destruction and P4/VDBE deletion.
3. Consolidate the source VDBE builder.
4. Connect generated parser/compiler owners.
5. Replace storage substitutes from PCache downward.
6. Expose the integrated engine through the final Zig API.
