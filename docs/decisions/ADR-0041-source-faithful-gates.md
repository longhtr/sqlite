# ADR-0041: Atomic source-fidelity gates and prototype freeze

## Status

Accepted.

## Context

The rebaseline correctly distinguished bounded evidence from completion, but the workflow still allowed declaration mappings, exact layouts, hook contracts, opcode-name mappings, and bounded substitute implementations to accumulate as apparent progress.

A VDBE differential worker exposed the structural problem. A handwritten C oracle program and the bounded Zig VM used different bytecode-construction models. Hardcoded jump addresses ignored the C builder's implicit `OP_Init`, causing an infinite-output loop. The differential found the mismatch, but the adapter violated source construction patterns and the runner lacked resource containment.

The project target requires SQLite's internal architecture, algorithms, states, ordering, allocation/failure behavior, and protocols—not merely compatible results from a different database design.

## Decision

- `docs/ENGINEERING_PROCESS.md` is the authoritative engineering workflow below the charter, scope, pinned source/profile, and this ADR.
- Work proceeds in dependency-closed atomic source units with behavioral-block, caller/callee, ownership, allocation, result, lock, callback, I/O, and test dossiers.
- Evidence states distinguish scaffold, source translation, internal trace equivalence, subsystem integration, assurance, and independent fidelity review.
- Entity/declaration/layout counts, parser hook contracts, opcode-name mappings, C-only test counts, and historical ABI coverage are non-progress accounting.
- The handwritten frontend/VDBE, reconstructed B-tree mutation, reduced pager/WAL models, and parallel manual bytecode programs are frozen substitutes. Their fixtures may be reused, but feature expansion cannot turn them into the final architecture.
- C and Zig adapters use a neutral symbolic operation specification where possible. Numeric control-flow duplication is prohibited when labels/fixups can be generated.
- Every child worker must have enforced time, output, memory, file, process, and descriptor limits before its evidence is trusted as contained.
- Integrated source translations atomically replace and retire duplicate production owners.
- Independent fidelity review is required before final promotion.

## Consequences

The current 348 parser action contracts and 98 bounded opcode-name mappings remain useful scaffolding but are not implementation completion. Existing source mappings and focused differentials remain evidence at their recorded scope and must be reevaluated when coupled dependencies are integrated.

The worker audit and 25,930-block active-profile behavioral inventory are now complete through executable gates. Feature expansion remains blocked by scaffold reclassification, assignment into dependency-closed atomic-unit dossiers, and source VDBE builder sequencing.

Progress reports prioritize integrated atomic units and native final-path tests. Historical metrics remain available for inventory and regression planning only.
