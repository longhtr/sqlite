# Source-Faithful Engineering Process

## Purpose

This is the single normative workflow for source translation, integration, evidence, containment, and reporting.

## Evidence states

```text
inventoried → source-context-reviewed → scaffolded (if needed)
→ source-translated → internal-trace-equivalent
→ subsystem-integrated → assurance-passed
```

Only assurance-passed contributes objective completion. Independent fidelity review is deferred and is not a current objective or gate. Layouts, declarations, mappings, hooks, bounded substitutes, and C-only tests are accounting or scaffolding.

## Atomic unit

Use a dependency-closed source unit. Its dossier identifies exact source and generated inputs; complete callers/callees and behavior; state, ownership, allocation, cleanup, results, locks, callbacks, I/O, and continuation; final and retiring owners; representation differences; neutral observations; and applicable fault/crash/concurrency/fuzz/performance obligations. Strongly connected functions and private state normally move together.

## Instruction and work lock

Persist user changes to scope, priorities, workflow, acceptance, reporting, or stop conditions before other work. Keep one dependency-critical unit active. Unrelated refactors, metrics, and prose wait unless explicitly requested or needed for a stop-line defect.

## Translation batch gate

A checkpoint promotion requires either:

- **200 short functions**: pinned source span below 10 physical lines; or
- **50 substantive functions**: pinned source span at least 10 physical lines and corresponding Zig behavior.

Count only net-new production behavior. Never count tests, adapters, wrappers around existing behavior, mappings, generated artifacts, prose, renames, pre-existing functions, or unreconciled historical claims. Each active entry carries the exact source/declaration hashes and atomic-unit owner; `zig build port-batch-checkpoint` accepts it only after canonical mapping and atomic-unit promotion.

Ordinary compilation, tests, generators, read-only audits, and incident recovery remain available below the threshold. `upstream/active-port-batch.json` owns the active delta, `upstream/historical-port-claims.json` quarantines retired no-credit claims, `upstream/port-checkpoints.json` owns accepted checkpoints, and `upstream/port-status.json` owns the generated summary. After a threshold, validate once, repair targeted failures, synchronize generated facts/prose once, then record a durable checkpoint. Broad suites additionally require a completed slice or explicit request.

## Execution budget and cadence

During normal implementation, spend at least 95% on source research and production porting and at most 5% on validation, status, process, and prose. Explicit audits and incidents may temporarily override this.

1. Complete admission and source review once.
2. Reach a translation threshold.
3. Run focused compile, invariant, differential, and applicable fault checks.
4. Integrate through the final owner and retire the duplicate.
5. Run broad gates once at promotion or handoff.
6. Regenerate ledgers and synchronized prose once.
7. Record exact evidence and blockers.

An unchanged repeated broad run adds no evidence.

## Admission and translation gates

Before coding, name the dependency boundary, final/retiring owners, complete source context, applicable tests, observations, and resource budgets. The translation preserves recognizable source decomposition and control order, widths and overflow, encoding, allocation timing/domain, sticky errors, cleanup, callbacks, locks, I/O, results, and invariants. Refactoring follows in a separate patch.

## Test and containment gates

C and Zig should consume one symbolic operation specification. Compare relevant branches, PCs, state, flags, aliases, allocation, callbacks, destructors, locks, VFS operations, files, results, and continuation—not only final output. Normalizers are narrow and mutation-tested.

Every oracle, native worker, fuzzer, and crash child uses `tools/bounded_subprocess.py` for wall time, process-group memory/address space, output, file size, CPU, process, descriptor, argument, and input limits. Timeouts, signals, limits, and host OOM invalidate evidence. See `docs/TESTING.md` for result ownership and interpretation.

## Integration and assurance

Integration requires the real native path to reach source-corresponding callers/state/callees, correct ownership and failure crossing, adapted native tests, retirement or test quarantine of the duplicate, and exactly one ledger owner. Run only applicable failure, crash, concurrency, fuzz, continuation, platform, and performance gates.

## Tool and documentation ownership

Every maintained script has one build/importing owner and bounded execution; `tools/verify_tooling.py` enforces this. Every maintained document has one purpose in `docs/README.md`; `tools/verify_docs.py` validates the registry, references, documented build targets, result-owner paths, and synchronized facts. Remove an artifact when its distinct purpose or owner disappears.

Ignored `.zig-cache/`, `zig-out/`, `.reference-build/`, and `.test-artifacts/` content is disposable output, never source or completion evidence.

## Incidents and status integrity

On mismatch, corruption, race, hang, runaway resources, host OOM, or safety failure: preserve bounded artifacts, classify the cause, minimize and regress project defects, audit siblings, invalidate affected evidence, and rerun from a clean checkpoint. Downgrade unsupported claims immediately; validator success never substitutes for semantic review.

## Reporting

Report concrete translated/integrated owners, final paths exercised, tests, retired substitutes, defects, and blockers. Do not headline percentages or scaffold counts. Mutable accounting belongs to `upstream/port-status.json`; a report does not end the active unit.
