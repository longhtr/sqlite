# Oracle and Migration Boundaries

Hybrid execution is test or migration infrastructure only. It is never native-port completion and is never permitted in a release artifact.

## Rules

1. Production engine behavior is owned only by Zig.
2. The C oracle runs in a separate process by default.
3. Private C layouts do not cross the oracle protocol.
4. Shared files, public byte formats, and explicit typed/text observations are preferred seams.
5. A test bridge records ownership, allocation, callbacks, locks, results, and teardown.
6. C test harnesses may invoke Zig bridge functions but may not implement missing engine behavior.
7. Every report labels evidence as oracle, transitional, hybrid, or native.
8. Production artifact audit requires zero C objects, including ABI shims.
9. C and Zig adapters consume one neutral symbolic operation specification when they model the same program or state machine; duplicated numeric control flow is prohibited.
10. Every oracle/native child is subject to the resource-containment gate in `docs/ENGINEERING_PROCESS.md` and `docs/TESTING.md`.

## Approved evidence seams

- database, journal, WAL, and WAL-index test artifacts;
- textual or typed operation protocols for utilities, parser, pager, B-tree, VDBE, SQL, and API observations;
- independent VFS traces and crash models;
- narrow test-only bridges for callbacks or opaque handles;
- the C Lemon parser used only as an oracle while the native parser is incomplete.

## Current state

Installed `libsqlite_zig` artifacts contain zero C objects. The old shim and partial extension table now live under `tests/legacy_c_abi/` and are linked only into a historical C-client executable.

The underlying configuration, formatting, logging, strings, functions, and module behavior still must be exposed and tested through Zig-native interfaces. Existing hybrid, canonical-header, and C-client tests remain bounded evidence until their observations are covered natively.
