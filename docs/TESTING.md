# Testing Strategy

## Purpose

Tests establish source fidelity for one named scope. They do not replace porting and do not turn scaffolding into implementation.

## Evidence classes

| Class | Meaning |
|---|---|
| control | Inputs, generation, ledgers, docs, containment, or artifact purity. |
| atomic | Unit/invariant/differential evidence for one dossier. |
| bounded-scaffold | Regression through a frozen substitute. |
| integrated-native | Final source-corresponding owners are reached. |
| oracle-only | C baseline health; no Zig credit. |
| release-assurance | Integrated path plus applicable failure/platform gates. |

## Efficient cadence

### Inner loop

Run only what can falsify the active translation:

1. compile analysis and source invariants;
2. focused Zig test;
3. neutral C/Zig differential;
4. reached OOM/I/O/crash/concurrency cases that apply.

### Promotion loop

Once per actual state transition, invalidation closure, or requested report:

```sh
zig build test -j1
zig build atomic-unit-audit source-ledger port-audit verify-config docs-test tooling-audit -j1
```

An unchanged repeated broad run adds no evidence. Testing and documentation must not consume the majority of engineering time.

## Differential rules

- C and Zig use isolated state and one symbolic operation specification.
- Compare branches, PCs, state, flags, aliases, allocations, callbacks, destructors, locks, VFS events, files, results, and continuation where applicable.
- Keep normalizers narrow and mutation-tested.
- Record source/profile/toolchain hashes, target, filesystem, seed, command, limits, and artifact.
- Never retry a deterministic mismatch into a pass.

## Worker containment

All child workers use `tools/bounded_subprocess.py` limits for wall time, process-group memory/address space, output, files, CPU, processes, descriptors, arguments, and input. A timeout, signal, limit event, host OOM, or filesystem-integrity warning invalidates the run until investigated and rerun cleanly.

## Assurance matrix

Apply only relevant dimensions to each unit; all apply before release:

- adapted upstream tests against final Zig owners;
- SQL Logic Test, metamorphic, and SQLancer campaigns;
- tokenizer/parser/VDBE/record/page/file/API/module fuzzing;
- reached allocation and VFS fault injection;
- durability simulation and physical process kills;
- threading modes, races, contention, and callback reentrancy;
- bidirectional database/journal/WAL continuation;
- AArch64/Btrfs and x86_64/ext4;
- pinned performance, memory, allocation, and I/O budgets.

The current 329,824-test upstream partition is oracle-only. Native upstream adaptation remains a release blocker.

## Solo fidelity-closure review

After assurance, freeze the implementation snapshot. In a fresh pass, re-read source, challenge dependency closure and every representation difference, rerun mutation/trace evidence, and record the review artifact and snapshot identity. This separation—not another person—satisfies the final review boundary for this solo project.

## Incident gate

Preserve the reproducer and artifacts; identify implementation, oracle, adapter, normalizer, containment, or environment cause; add a regression when project-controlled; invalidate affected evidence; then rerun cleanly. No unexplained defect may remain at release.
