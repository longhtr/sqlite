# ADR-0001: Source-entity semantic port

## Status

Accepted, as strengthened by ADR-0041.

## Decision

Map every in-scope upstream source and behavioral responsibility to one or more Zig declarations/generated artifacts. Preserve control flow and obligations during fidelity; idiomatize separately. One-to-many and many-to-one mappings are explicit. ADR-0041 requires dependency-closed atomic units because declaration identity alone does not cover branches, switch cases, cleanup labels, generated bodies, or subsystem integration.

## Consequences

Upstream traceability and reviewability take priority over early redesign. Evidence is profile-specific and is invalidated by affected changes. Entity and declaration mappings are accounting until concrete behavior reaches the evidence gates in `docs/ENGINEERING_PROCESS.md`.
