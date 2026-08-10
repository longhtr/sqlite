# Risk Register

| ID | Risk | Required mitigation | Status |
|---|---|---|---|
| RISK-001 | Bounded/scaffold implementations are mistaken for completed subsystems. | Keep machine status authoritative; close only source-derived integration and assurance gates. | blocking |
| RISK-002 | Structural inventories or legacy mappings are mistaken for semantic review. | Require complete source context and executable obligations per atomic unit. | blocking |
| RISK-003 | Simplified state models diverge from SQLite internals. | Port coupled headers/state/algorithms before abstraction and retire substitutes atomically. | blocking |
| RISK-004 | Handwritten frontend, VDBE, B-tree, pager, or WAL paths become permanent. | Connect generated/source owners and remove or test-quarantine duplicates. | blocking |
| RISK-005 | C ABI history distorts the Zig-native product or re-enters artifacts. | Keep behavior in scope, transport excluded, and retain zero-C artifact audit. | active |
| RISK-006 | Storage/concurrency evidence is generalized beyond tested profiles. | Complete mode/device/platform matrices, physical kills, races, and continuation tests. | blocking |
| RISK-007 | C-oracle or differential adapters hide mismatches. | Isolate processes, use symbolic protocols, narrow/mutation-test normalizers, and preserve failures. | active |
| RISK-008 | Zig safety/idioms alter arithmetic, ownership, ordering, or results. | Translate first; use explicit widths/cleanup and focused boundary/fault traces. | active |
| RISK-009 | Upstream changes invalidate mappings/evidence silently. | Maintain source ledgers and rehearse `docs/UPSTREAM_SYNC.md` before release. | blocking |
| RISK-010 | Test scale or workers exhaust host resources. | Use bounded execution, deterministic sharding, and treat host OOM as invalid evidence. | active |
| RISK-011 | Removing excluded C transport drops underlying SQLite behavior. | Map every dispatched responsibility to a final Zig owner before deleting transitional tests. | blocking |
| RISK-012 | Documentation or test-result prose becomes duplicate/stale authority. | Keep `docs/README.md` as the purpose registry, mutable facts machine-owned, and verify references/targets/result owners. | mitigated |
| RISK-013 | Toolchain/package changes invalidate generated facts. | Fail closed on pinned identities and explicitly regenerate/review affected artifacts. | active |
| RISK-014 | Historical function claims diverge from canonical mappings and atomic ownership. | Grant no credit to the retired quantity ledger; require exact declaration hashes, promoted atomic owners, and durable checkpoints. | blocking |
| RISK-015 | Uncommitted workspace state prevents checkpoint recovery and clean-checkout reproduction. | Preserve a reviewed repository checkpoint before relying on any implementation or evidence state. | blocking |

A risk closes only with linked executable evidence; scope reduction does not close behavioral risk.
