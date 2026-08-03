# Porting Rules

1. Port only from pinned canonical source; the amalgamation is oracle input.
2. Keep one dependency-closed atomic unit active.
3. Before coding, review its implementation, callers, callees, assertions, branches, cleanup, predicates, generated inputs, and tests.
4. Record state, ownership, allocation, results, locks, callbacks, I/O, continuation, final owner, and owner to retire.
5. Preserve source decomposition and control order; redesign only after equivalence in a separate patch.
6. Preserve exact widths, overflow, encoding, allocation/failure points, sticky state, cleanup, callback/lock/I/O order, and extended results.
7. Map each responsibility to a real declaration/artifact, folded owner, or justified no-code disposition.
8. Keep C ABI transport outside the product without dropping dispatched behavior.
9. Keep pointer casts and C calling conventions in test/oracle bridges; private source layouts may model internal engine state but do not define the public Zig API.
10. Use explicit SQLite result paths; `errdefer` does not replace result-code cleanup.
11. Use one neutral symbolic C/Zig protocol and bounded workers.
12. During translation run targeted compile, unit, differential, and fault checks only.
13. Run broad suites and regenerate aggregate facts once at promotion, handoff, invalidation closure, or requested report.
14. Spend at least 80% of normal execution on source analysis, translation, integration, and targeted evidence; keep documentation/accounting at or below 5%.
15. Never weaken scope, expectations, normalizers, or containment to pass.
16. Never promote a layout, hook, placeholder, name mapping, bounded substitute, or C-only test as implementation.
17. Integrate atomically and remove/quarantine the duplicate production owner.
18. Independent review is required for final fidelity credit.
19. Downgrade unsupported claims and dependent evidence immediately.
20. Questions and passing tests are not stopping points; resume the active unit unless the incident gate blocks it.
21. A host OOM invalidates the run; reduce build concurrency and rerun cleanly.
22. Report concrete translated/integrated owners, evidence, retired substitutes, defects, and blockers—not percentages or scaffold counts.
