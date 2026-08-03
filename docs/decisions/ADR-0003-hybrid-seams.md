# ADR-0003: Test-only oracle and hybrid seams

## Status

Accepted as test/migration infrastructure; production hybrid and C ABI allowances are superseded by ADR-0040, and worker/test construction is strengthened by ADR-0041.

## Decision

Use separate-process protocols, files, and narrow test bridges to compare C and Zig. Exactly one engine owns each state object in a test. Private C layouts do not cross the protocol. C harnesses may invoke Zig bridges but may not implement missing native behavior. Equivalent adapters consume neutral symbolic operations where possible, and every child is resource-contained under `docs/ENGINEERING_PROCESS.md`.

## Evidence

Existing VFS/callback and isolated-worker probes remain useful bounded evidence.

## Stop condition

A seam is rejected if layout, ownership, callback, linkage, sanitizer, lock, teardown, symbolic-control-flow, or resource-containment behavior is unresolved. No seam may enter a production artifact.
