# Decision Records

Maintained ADRs record durable fidelity and architecture decisions. ADR-0040 defines the pure-Zig product boundary and supersedes the earlier production C ABI decision. ADR-0041 makes dependency-closed atomic source units, internal traces, prototype retirement, worker containment, and assurance mandatory, and classifies raw scaffold counts as non-progress accounting. Independent fidelity review is deferred.

Historical bounded-phase evidence remains under `upstream/phase*-manifest.json` and `tests/fixtures/`; it does not establish subsystem completion. “Accepted” in a focused fidelity ADR accepts that design/evidence scope, not atomic-unit integration or whole-subsystem completion. All evidence is interpreted through ADR-0041 and `docs/ENGINEERING_PROCESS.md`. Removed completion ADRs remain available in Git history.
