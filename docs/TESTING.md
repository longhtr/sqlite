# Testing Strategy

## Purpose

Tests establish evidence for one named scope. They do not replace source porting or turn scaffolding into implementation. This document owns test interpretation, result ownership, and oracle boundaries.

## Evidence classes

| Class | Meaning |
|---|---|
| control | Inputs, generation, ledgers, docs, containment, or artifact purity. |
| atomic | Unit/invariant/differential evidence for one source unit. |
| bounded-scaffold | Regression through a frozen substitute. |
| integrated-native | Final source-corresponding owners are reached. |
| oracle-only | C baseline health; no Zig credit. |
| release-assurance | Integrated path plus applicable failure/platform gates. |

## Result ownership

Test output is ephemeral unless a named maintained artifact owns it. Do not copy broad pass logs or volatile counts into ADRs or status prose.

| Scope | Invocation | Result owner and purpose |
|---|---|---|
| Aggregate regression | `zig build test -j1` | `build.zig` composes bounded native, differential, oracle, durability, and control modules; stdout is not a maintained artifact. |
| Targeted control diagnosis | `zig build port-batch-audit port-batch-gate-test atomic-unit-audit source-ledger port-audit verify-config docs-test tooling-audit -j1` | JSON ledgers and verifier exit status; these are aggregate dependencies and are run directly only to isolate/repair a control failure. |
| Translation checkpoint promotion | `zig build port-batch-checkpoint -j1` | `upstream/active-port-batch.json` and `upstream/port-checkpoints.json`; promotion fails below threshold or without exact canonical ownership and durable evidence. |
| Utility differentials | `zig build bitvec-differential hash-differential varint-differential byteorder-differential string-differential utf-differential random-differential random-process-differential numeric-differential builtin-registry-differential infrastructure-differential -j1` | Matching `tools/*_differential.py`, native worker under `tests/differential/`, and oracle worker under `reference/c_oracle/`; results are scoped observations. |
| Durability models | `zig build durability-spike rollback-differential -j1` | `tools/durability_probe.zig` and `tools/rollback_differential.py`; bounded model evidence only. |
| Upstream C baseline | `zig build test-upstream` | `tools/test_upstream.py`; the immutable dated result is `reference/c_oracle/UPSTREAM_TEST_EVIDENCE.md` and grants oracle-only evidence. |
| Current machine status | `zig build port-audit` | `upstream/port-status.json`; generated accounting, not a test transcript or completion metric. |
| Compatibility summary | `zig build compatibility-report` | `zig-out/compatibility-report.json`; disposable digest-backed output emitted only after the aggregate and export audit, not maintained evidence. |

`tools/verify_docs.py` checks that documented build targets and result-owner paths exist. `tools/verify_tooling.py` checks every Python entrypoint has a current owner, bounded child execution, and no orphan manual exception.

## Checkpoint cadence

Checkpoint promotion is batch-gated by `upstream/active-port-batch.json`, `upstream/port-checkpoints.json`, and `zig build port-batch-checkpoint`. Ordinary builds and read-only controls are never disabled by an incomplete batch.

During translation run only focused compile/invariant, unit, neutral differential, and reached fault checks. Once per state transition, invalidation closure, or requested handoff, run the aggregate regression. Its control dependencies must not be rerun unchanged as a second promotion command; invoke them separately only for targeted diagnosis. Never retry a deterministic mismatch into a pass. A durable promotion receipt identifies the exact source and Zig trees, command, and result owner; command prose alone is not evidence.

## Differential and worker rules

- Isolate C and Zig state; share a symbolic operation specification where possible.
- Compare relevant branches, PCs, state, flags, aliases, allocations, callbacks, destructors, locks, VFS events, files, results, and continuation.
- Keep normalizers narrow and mutation-tested.
- Record source/profile/toolchain hashes, target, filesystem, seed, command, limits, and bounded artifact when evidence is promoted.
- Route all children through `tools/bounded_subprocess.py`; timeout, signal, limit, host OOM, or filesystem-integrity warnings invalidate the run.

## Oracle and migration boundaries

C is test/migration infrastructure only. It runs in a separate process by default, never owns production behavior, and never shares private SQLite state with Zig. Approved seams are public byte formats, database/journal/WAL files, neutral typed/text protocols, independent VFS traces/crash models, and narrow test-only callback/opaque-handle bridges. Equivalent adapters may not duplicate numeric control flow when symbolic labels/fixups are available. Every report labels evidence oracle, transitional, bounded-scaffold, or integrated-native.

Installed production artifacts must contain zero C objects. Historical C ABI and hybrid probes remain bounded regressions until their observations move to native Zig API tests.

## Release assurance

Apply relevant dimensions per unit and all dimensions before release: adapted upstream tests against final Zig owners; SQL Logic Test, metamorphic, and SQLancer; parser/VDBE/record/page/file/API fuzzing; reached allocation and VFS faults; durability simulation and physical kills; threading/race/contention/reentrancy; bidirectional database/journal/WAL continuation; AArch64/Btrfs and x86_64/ext4; and pinned performance, memory, allocation, and I/O budgets.

The dated upstream result is C-oracle-only. Native upstream adaptation remains a release blocker.

## Incident handling

Preserve bounded reproducer/artifacts, classify implementation/oracle/adapter/normalizer/containment/environment cause, add a regression for project defects, invalidate affected evidence, and rerun cleanly. No unexplained defect may remain at release.
