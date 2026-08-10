# sqlite-zig

A source-faithful Zig port of SQLite 3.53.4.

> **Incomplete. Do not use with production data.**

## Product

The target is the selected SQLite core implemented entirely in Zig: the same architecture, SQL behavior, storage formats, transactions, failures, concurrency, and reliability properties, exposed through a Zig-native API. It is not a C `libsqlite3` ABI replacement. C is limited to pinned source and isolated test/oracle infrastructure.

## State

The final parser/compiler/VDBE/storage pipeline and complete Zig API do not yet exist. Authoritative machine and engineering state: [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) and [`upstream/port-status.json`](upstream/port-status.json).

## Read first

1. [`docs/PORTING_CHARTER.md`](docs/PORTING_CHARTER.md) — mission and completion.
2. [`docs/SCOPE.md`](docs/SCOPE.md) — pinned target and exclusions.
3. [`docs/ENGINEERING_PROCESS.md`](docs/ENGINEERING_PROCESS.md) — mandatory workflow.
4. [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) — current audit.
5. [`docs/EXECUTION_PLAN.md`](docs/EXECUTION_PLAN.md) — dependency order.

[`docs/README.md`](docs/README.md) inventories all maintained documentation.

## Commands

```sh
zig build test -j1            # aggregate regression and control graph
zig build test-upstream       # C oracle only; not Zig progress
zig build compatibility-report
```

Pinned inputs are recorded in `upstream/SQLITE_BASELINE` and `upstream/SQLITE_BUILD_PROFILE.json`.
