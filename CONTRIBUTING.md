# Contributing

## Before coding

1. Read `docs/PORTING_CHARTER.md`, `docs/SCOPE.md`, `docs/ENGINEERING_PROCESS.md`, and `docs/PORTING_RULES.md`.
2. Select one dependency-closed atomic unit from the critical queue.
3. Complete its dossier: source, callers, callees, ownership, state, allocation, results, locks, callbacks, I/O, tests, oracle, final owner, and owner to retire.
4. Declare the targeted test commands.

## Patch discipline

- Keep one unit active.
- Translate pinned canonical source before refactoring.
- Preserve control flow, state, allocation/failure points, cleanup, callback/lock/I/O order, results, and continuation.
- Keep C in isolated oracle/test infrastructure.
- Use one symbolic protocol for C/Zig state-machine tests.
- Do not expand frozen substitutes, weaken tests, or promote scaffolding.
- Run targeted checks during implementation; run broad gates once at promotion or handoff.
- Put ergonomic cleanup in a later patch.

## Review

A patch may advance only to the evidence state it proves. Independent fidelity review is required for final credit. High-risk parser, compiler, VDBE, B-tree, pager, WAL, VFS, allocator, threading, file-format, and public-API work also requires Zig-safety and behavioral review.
