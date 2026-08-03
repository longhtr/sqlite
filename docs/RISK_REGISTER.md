# Risk Register

| ID | Risk | Required mitigation | Status |
|---|---|---|---|
| RISK-001 | Bounded implementations are mistaken for completed SQLite subsystems. | Keep `port-status.json` authoritative; close only source-derived subsystem gates. | blocking |
| RISK-002 | 3,892 entities are unmapped, 790 are legacy candidates, and 402 active legacy target references are unresolved (416 across all mappings). | Resolve/discard candidates and context-review every active atomic source unit. | blocking |
| RISK-003 | Simplified internal models cannot represent SQLite state. | Port active internal headers and coupled algorithms before abstraction. | blocking |
| RISK-004 | The handwritten frontend diverges from Lemon; all 348 typed action contracts exist but concrete owners and compiler/planner execution do not. | Integrate source-translated AST owners, recovery, resolver, compiler, planner, and VDBE builder, then retire the handwritten frontend. | blocking |
| RISK-005 | The old C ABI replacement goal continues to shape code and completion metrics. | Make the Zig API responsibility map authoritative; treat exports and canonical-header tests as transitional evidence. | blocking |
| RISK-006 | C enters production artifacts again. | Installed `libsqlite_zig` archives now audit at zero C; keep the exact-member audit as a permanent release gate. | mitigated |
| RISK-007 | Whole-tree reconstruction differs from SQLite balancing. | Port incremental B-tree algorithms and run graph/fault/continuation matrices. | blocking |
| RISK-008 | Pager/WAL evidence covers too little of the durability model. | Expand source fidelity, mode matrices, simulator mutation tests, and physical process-kill tests. | blocking |
| RISK-009 | Upstream tests pass only against C. | Adapt and track applicable upstream tests against the Zig engine. | blocking |
| RISK-010 | Global registries and connections lack SQLite mutex discipline. | Port threading modes, lock ownership, callback state, and race/process stress. | blocking |
| RISK-011 | Differential adapters or normalizers hide mismatches. | Separate processes, independent checkers, mutant testing, and normalizer review. | active |
| RISK-012 | Zig safety or idioms alter arithmetic, aliasing, cleanup, or result behavior. | Fidelity-first patches, explicit casts/ownership, and focused boundary tests. | active |
| RISK-013 | Upstream fixes cannot be mapped quickly. | Complete the source ledger and rehearse a real upstream sync before release. | blocking |
| RISK-014 | AArch64/Btrfs evidence is generalized to x86_64/ext4. | Run target-native locking, durability, and performance gates. | active |
| RISK-015 | Test scope exceeds practical feedback budgets. | Shard deterministic PR, nightly, weekly, and release suites without weakening release gates. | active |
| RISK-016 | Removing C transport accidentally drops SQLite behavior. | Map each formatter, configuration, callback, module, and public responsibility to Zig before deleting transitional code. | blocking |
| RISK-017 | “Zig-native API” becomes permission to redesign semantics. | Keep a low-level source-corresponding Zig API that preserves exact results and lifetimes; add ergonomic wrappers only later. | blocking |
| RISK-018 | Scaffold counts—entities, declarations, layouts, parser hooks, and opcode names—are mistaken for implementation progress. | Report atomic units at source-translated/integrated/assured/reviewed states; retain raw counts as non-progress accounting only. | blocking |
| RISK-019 | Bounded handwritten frontend/VDBE/B-tree/pager/WAL substitutes become permanent through incremental extension. | Freeze substitute expansion, port dependency-closed source units, switch ownership atomically, and remove/quarantine the prototype. | blocking |
| RISK-020 | A looping or noisy test worker exhausts host memory or disk before reporting a mismatch. | Central bounded runner now enforces timeout, process-group RSS/address-space, output, file-size, CPU, process, descriptor, argument, and input limits; tooling audit mutation-tests failures. | mitigated |
| RISK-021 | Declaration inventory alone misses behavior in branches, switch cases, cleanup labels, assertions, and generated bodies. | Keep the completed behavioral-block inventory verified and assign every applicable block and trace obligation to dependency-closed atomic-unit dossiers. | blocking |
| RISK-022 | The implementer promotes its own narrow evidence without independent source-fidelity review. | Require separate fidelity review of source closure, representation differences, internal traces, failure behavior, and integration. | blocking |
| RISK-023 | Duplicate or orphan documentation revives stale goals, commands, or progress claims. | Keep one complete Markdown inventory, merge overlapping entry guides, and verify every maintained document plus synchronized status facts. | mitigated |
| RISK-024 | Host package upgrades silently invalidate pinned compiler and libclang evidence. | Fail closed on executable hashes; explicitly rebaseline tool metadata, regenerate compiler-derived layouts/inventories, and require unchanged source identities before accepting a new toolchain. | active |
| RISK-025 | Structural inventory closure or bulk-generated mappings are mistaken for semantic source-context review. | Keep bulk targets inventoried; terminal context-review dossiers now require verified nonempty implementation/caller/callee/assertion-branch-cleanup/upstream-test evidence and reject placeholder boundaries; immediately downgrade unsupported higher-state promotions with dependent evidence invalidation. | blocking |

A risk closes only with linked executable evidence. Scope reduction does not close a behavioral port risk.
