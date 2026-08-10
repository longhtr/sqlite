# Documentation Inventory

## Purpose

This is the single documentation entry point and the complete inventory of maintained project Markdown. It assigns one non-overlapping purpose to each file so stale phase narratives, duplicate authority, and orphan documentation are detectable. `tools/verify_docs.py` verifies this inventory against the repository.

Vendored files under `upstream/sqlite/`, build outputs, generated data files, and failure artifacts are not project documentation. `AGENTS.md` is live agent operational memory rather than contributor documentation; it points to this registry. Small README files beside generated or test artifacts are maintained because they explain provenance and evidence boundaries.

## Reading order

New contributors should read:

1. `README.md` for the public warning, goal, state pointers, and core commands.
2. `docs/PORTING_CHARTER.md` for the mission, authority, and completion definition.
3. `docs/SCOPE.md` for the pinned target and explicit exclusions.
4. `docs/ENGINEERING_PROCESS.md` for the mandatory atomic-unit workflow and evidence gates.
5. `docs/CURRENT_STATE.md` and `upstream/port-status.json` for current facts and blockers.
6. `docs/EXECUTION_PLAN.md` for dependency order and subsystem exit gates.
7. `docs/TESTING.md` before constructing or interpreting evidence.
8. `CONTRIBUTING.md` before submitting a patch.

When documents conflict, use the authority order in `docs/PORTING_CHARTER.md`.

## Repository map

| Path | Responsibility |
|---|---|
| `config/` | Pinned profile, feature, limit, infrastructure, and target facts consumed by Zig. |
| `src/core/` | Native engine work: source translations, generated-table consumers, and explicitly bounded migration prototypes. |
| `src/abi/` and `include/` | Transitional C-layout/header facts used by migration and tests; not the final Zig API and not installed product requirements. |
| `generated/` | Reproducible ABI, internal-layout, keyword, opcode, and parser artifacts derived from pinned inputs. |
| `upstream/sqlite/` | Vendored canonical SQLite source specification; its own documentation is upstream-owned. |
| `upstream/*.json` | Machine-readable source, behavior, mapping, public-responsibility, historical-evidence, and status ledgers. |
| `upstream/atomic-units/` | Dependency-closed source-unit dossiers and evidence states. |
| `reference/` | C oracle, historical hybrid probe, and external worker protocol; never production engine behavior. |
| `tests/` | Native, differential, fault, crash, concurrency, file-format, fuzz, toolchain, and historical migration evidence. |
| `tools/` | Bounded, batch-gated generators, auditors, differential runners, and CI orchestration; every entrypoint has a build or importing owner. |
| `docs/` | Maintained policy, architecture, status, plans, risks, specialized controls, and ADRs. |

`.zig-cache/`, `zig-out/`, `.reference-build/`, and `.test-artifacts/` are ignored build/evidence outputs, not source or maintained documentation.

## Entry and contributor documents

| Document | Distinct purpose |
|---|---|
| `README.md` | Brief public project warning, goal, authoritative state pointers, starting links, and core commands. |
| `CONTRIBUTING.md` | Minimal contributor prerequisites and patch expectations. |
| `docs/README.md` | Documentation entry point, complete inventory, and anti-duplication policy. |

## Normative documents

| Document | Distinct purpose |
|---|---|
| `docs/PORTING_CHARTER.md` | Highest-level mission, authority order, fidelity principles, and final completion gate. |
| `docs/SCOPE.md` | Pinned source/profile, included behavior, target platforms, and explicit deferrals. |
| `docs/ENGINEERING_PROCESS.md` | Sole enforceable atomic-unit workflow: batching, promotion, containment, integration, incidents, and reporting. |
| `docs/TESTING.md` | Evidence classes, result ownership, worker/oracle boundaries, cadence, and release assurance. |

## Architecture, status, and planning

| Document | Distinct purpose |
|---|---|
| `docs/ARCHITECTURE.md` | Target SQLite pipeline, product/test boundaries, and current architecture deviations. |
| `docs/CURRENT_STATE.md` | Verification-checked machine summary, subsystem matrix, reusable work, and immediate blockers. |
| `docs/EXECUTION_PLAN.md` | Dependency graph, work packages, subsystem exit gates, and final release path. |
| `docs/RISK_REGISTER.md` | Live risks, required mitigations, and blocking/active status. |

## Specialized controls

| Document | Distinct purpose |
|---|---|
| `docs/DURABILITY_MODEL.md` | Bounded rollback/WAL durability evidence and required final mode matrix. |
| `docs/THREAT_MODEL.md` | Security, corruption, hostile-input, extension, and test-infrastructure threats. |
| `docs/UPSTREAM_SYNC.md` | Procedure for importing a future SQLite baseline and invalidating affected evidence. |

## Decision records

| Document | Distinct purpose |
|---|---|
| `docs/decisions/README.md` | ADR interpretation, historical status, and supersession rules. |
| `docs/decisions/ADR-0001-semantic-port.md` | Establish source/behavior identity mapping and traceability. |
| `docs/decisions/ADR-0002-variadic-abi-shims.md` | Preserve the superseded C-ABI decision as historical rationale. |
| `docs/decisions/ADR-0003-hybrid-seams.md` | Define isolated oracle and test-only hybrid seams. |
| `docs/decisions/ADR-0004-parser-generation.md` | Define deterministic Lemon generation and action-contract status. |
| `docs/decisions/ADR-0005-durability-model.md` | Define the independent bounded durability simulator's evidence role. |
| `docs/decisions/ADR-0006-bitvec-fidelity.md` | Record BitVec representation and failure behavior. |
| `docs/decisions/ADR-0007-hash-fidelity.md` | Record Hash structure, ownership, and allocation behavior. |
| `docs/decisions/ADR-0008-varint-fidelity.md` | Record varint encoding and permissive decoding behavior. |
| `docs/decisions/ADR-0009-byteorder-fidelity.md` | Record explicit big-endian field encoding behavior. |
| `docs/decisions/ADR-0010-string-fidelity.md` | Record SQLite byte-oriented case-folding behavior. |
| `docs/decisions/ADR-0011-utf-primitive-fidelity.md` | Record permissive UTF primitive behavior. |
| `docs/decisions/ADR-0012-random-injection-fidelity.md` | Record PRNG-core separation from entropy and mutex adapters. |
| `docs/decisions/ADR-0013-numeric-and-formatting-fidelity.md` | Record numeric-state fidelity and bounded formatter evidence. |
| `docs/decisions/ADR-0015-memory-and-lookaside-fidelity.md` | Record allocator and two-size lookaside contracts. |
| `docs/decisions/ADR-0016-mutex-and-initialization-fidelity.md` | Record mutex modes and initialization ordering. |
| `docs/decisions/ADR-0039-rebaseline-complete-port.md` | Withdraw bounded-phase completion claims and require whole-port rebaseline. |
| `docs/decisions/ADR-0040-pure-zig-product.md` | Define the zero-C product and Zig-native API boundary. |
| `docs/decisions/ADR-0041-source-faithful-gates.md` | Require atomic units, internal traces, prototype freeze, containment, and assurance. |

## Artifact-local documentation

| Document | Distinct purpose |
|---|---|
| `generated/abi/README.md` | Explain provenance and target restrictions for generated ABI layout facts. |
| `generated/parser/README.md` | Explain parser artifact generators, contents, and non-completion status. |
| `reference/c_oracle/README.md` | Explain how the pinned C amalgamation is produced and limited to oracle use. |
| `reference/c_oracle/UPSTREAM_TEST_EVIDENCE.md` | Record the exact platform and result of the upstream C-oracle test run. |
| `reference/hybrid_probe/README.md` | Bound the historical Zig-callback/VFS hybrid feasibility probe. |
| `reference/protocol/PROTOCOL.md` | Specify the versioned external differential-worker metadata protocol. |
| `tests/toolchain/README.md` | Explain the pinned Zig/toolchain compatibility probes. |

## Maintenance rules

- Mutable status facts live in `upstream/port-status.json`; synchronized prose summaries are verification-checked.
- `AGENTS.md` references this complete registry rather than duplicating every path; `tools/verify_docs.py` makes that reference transitive and exact.
- A new maintained Markdown file requires a unique purpose in this inventory.
- If a document's purpose becomes a subset of another, merge its unique content and remove it rather than retaining a second authority.
- ADRs are retained when superseded; their status and superseding decision must be explicit.
- Present-tense claims in ADRs must be clearly separated from historical decisions and refreshed when they describe current integration.
- Machine-generated files, vendored SQLite documentation, build outputs, and failure artifacts are outside this inventory.
