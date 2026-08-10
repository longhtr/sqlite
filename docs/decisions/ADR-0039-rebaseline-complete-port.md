# ADR-0039: Rebaseline on complete source-faithful port

## Status

Accepted, as amended by ADR-0040 and ADR-0041.

## Context

Historical milestones closed bounded slices and later described them as completed phases. The code exports many symbols and has valuable low-level evidence, but parser, compiler, planner, VDBE, storage, and public behavior remain incomplete.

## Decision

- Withdraw subsystem and project completion claims based on bounded profiles.
- Keep historical manifests as regression evidence only.
- Make `upstream/port-status.json` authoritative.
- Audit existing code in dependency-closed atomic source units and execute `docs/ENGINEERING_PROCESS.md` plus `docs/EXECUTION_PLAN.md` until all active behavioral responsibilities close.
- Permit no completion claim through scope reduction, wrapper presence, or exported symbols.

ADR-0040 later clarified that the target is a pure-Zig product and Zig-native API, not a drop-in C ABI library. ADR-0041 later classified scaffold counts as non-progress accounting and froze bounded substitute architectures pending source-translated replacement.

## Consequences

Legacy exports, canonical-header tests, hybrid paths, hook contracts, layouts, and opcode-name mappings remain transitional/scaffold evidence. Progress is measured by atomic source translation, internal trace equivalence, native integration, assurance, and production purity. Independent fidelity review is deferred.
