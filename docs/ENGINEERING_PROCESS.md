# Source-Faithful Engineering Process

## Purpose

Deliver SQLite’s implementation, not a compatible substitute. This document defines the mandatory unit, evidence, integration, containment, and reporting gates.

## Evidence states

```text
inventoried
→ source-context-reviewed
→ scaffolded (only if needed)
→ source-translated
→ internal-trace-equivalent
→ subsystem-integrated
→ assurance-passed
→ independently-fidelity-reviewed
```

Only the final state contributes objective completion. In this solo project, “independently” means a review pass isolated from implementation: immutable snapshot, fresh source re-read, adversarial checklist, mutation evidence, and recorded artifact. It does not require another person. Layouts, declarations, mappings, hooks, action/opcode names, bounded substitutes, and C-only tests are accounting or scaffolding.

## Atomic unit

Work uses **dependency-closed atomic source units**. A dossier records:

1. source files, spans, identities, hashes, predicates, generated inputs, and behavioral blocks;
2. complete implementation, callers, callees, assertions, branches, cleanup, and upstream tests;
3. input/output, state, ownership, allocation, results, locks, callbacks, I/O, and continuation;
4. dependency boundary and one final production owner;
5. representation differences;
6. neutral oracle protocol and internal observations;
7. applicable OOM, I/O, crash, malformed-input, concurrency, fuzz, and performance obligations;
8. the bounded owner to retire.

Strongly connected functions and private state normally move together.

## Efficient execution

### Work lock

Keep one dependency-critical dossier active. Questions, passing tests, and corrected mismatches do not end it. Unrelated refactors, naming changes, metrics, and documentation wait unless they resolve a stop-line defect.

### Effort budget

During normal unit execution:

- **80% or more:** source analysis, translation, integration, and targeted behavioral evidence;
- **15% or less:** broader assurance and review preparation;
- **5% or less:** aggregate ledgers, status, and documentation.

Incidents may temporarily override the budget. If process work occupies two consecutive checkpoints without advancing or invalidating the active unit, stop and simplify the process.

### One-pass cadence

1. Lock the unit and complete admission once.
2. Translate with targeted compile/unit checks.
3. Build one neutral differential and applicable fault cases.
4. Integrate through the final owner and retire the duplicate.
5. Run broad gates once at promotion or handoff.
6. Regenerate aggregate ledgers and synchronized prose once.
7. Perform the isolated fidelity-closure review on the immutable result.

Do not rerun the full suite after every edit. Do not regenerate inventories or rewrite prose unless a mapping, evidence state, synchronized fact, or incident changed.

## Admission gate

Before coding behavior:

- dossier and dependency closure are complete;
- final and retiring owners are named;
- source context and applicable tests are reviewed;
- oracle observations and resource budgets are declared;
- no substitute algorithm or parallel production owner is planned.

Automation may collect identities and call sites but may not infer semantic review.

## Translation gate

The fidelity patch:

- follows canonical source and preserves recognizable decomposition and control order;
- preserves widths, overflow, encoding, allocation timing/domain, sticky errors, cleanup, callbacks, locks, I/O, and results;
- keeps source invariants;
- does not redesign or expand a frozen substitute;
- records only the evidence state reached.

Idiomatic cleanup is a separate later patch.

## Test gate

C and Zig consume one symbolic operation specification when possible. Compare applicable branches, PCs, states, flags, aliases, allocations, callbacks, destructors, locks, VFS operations, files, results, and continued use—not only final output. Normalizers are narrow and mutation-tested.

The inner loop runs only the unit’s compile, invariant, differential, and fault checks. The promotion loop runs aggregate controls and `zig build test -j1` once before transition, handoff, invalidation closure, or requested report.

## Mandatory worker containment

Every oracle, native worker, fuzzer, and crash child has enforced wall time, process-group memory/address space, output, file size, CPU, process, descriptor, argument, and input limits through `tools/bounded_subprocess.py`. Signals, timeouts, and limit events fail evidence and preserve bounded artifacts.

Broad builds use low concurrency on memory-pressured hosts. A host OOM invalidates the run and requires a clean lower-concurrency rerun.

## Integration and retirement gate

A unit is integrated only when:

- the real native path reaches source-corresponding callers, state, and callees;
- ownership and failures cross boundaries correctly;
- adapted native tests exercise the path;
- the bounded duplicate is removed or test-quarantined;
- ledgers identify exactly one production owner.

## Assurance and review

Run only applicable failure, crash, concurrency, fuzz, continuation, platform, and performance gates. After assurance, start a fresh isolated review pass. Re-read source without relying on implementation notes, challenge unit closure and representation differences, rerun mutation/trace evidence, and record the snapshot plus review artifact before final promotion.

## Status integrity

Unsupported claims are downgraded immediately with dependent evidence invalidated. Remove code that exists only for an excluded transport, regenerate affected ledgers, synchronize facts, and rerun affected gates. Validator success never substitutes for semantic review.

## Incident gate

On unexplained mismatch, corruption, race, hang, runaway resource use, host OOM, or safety failure:

1. preserve artifacts and reproducer;
2. identify implementation, oracle, adapter, normalizer, containment, or environment cause;
3. minimize and add a regression when project-controlled;
4. audit siblings and invalidate affected evidence;
5. rerun from a clean checkpoint before resuming.

## Reporting

Report engineering changes, final-path owners reached, source units translated/integrated/assured, tests that exercised those owners, retired substitutes, defects, and blockers. Do not headline percentages or scaffold counts. Machine accounting remains in `upstream/port-status.json` and is consulted only when explicitly requested.

A report is a checkpoint, not a reason to abandon the active unit.
