# Scope

## Selected port

- SQLite 3.53.4, check-in `bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
- Profile: `upstream/SQLITE_BUILD_PROFILE.json`.
- `SQLITE_THREADSAFE=1`, including supported runtime modes.
- Complete active-profile tokenizer, parser, compiler, planner, VDBE, storage, transaction, built-in, pragma, VFS, and public behavior.
- Zig-native API and Zig-only product artifacts.
- Bidirectional database, rollback-journal, and WAL continuation.
- Declared durability matrix on AArch64/Btrfs and x86_64/ext4.

`upstream/source-scope.json`, the active source inventory, generated inputs, and behavioral inventory define the accountable work; branches, cases, labels, assertions, and generated bodies remain additional responsibilities.

## Product exclusions

The selected port need not provide:

- the C `libsqlite3` ABI, symbols, SONAME, headers, varargs, or `va_list`;
- unchanged C-client compilation;
- unchanged binary C extensions or `sqlite3_api_routines` transport.

These may become a separate adapter project. Their underlying SQLite behavior remains in scope through Zig-native owners.

## Deferred profiles

Separate future ports:

- FTS5, R-tree, Session/preupdate, and Carray;
- the command-line shell;
- Windows and macOS VFSes;
- 32-bit and big-endian targets;
- non-release compile-time combinations.

## Production purity

Production engine modules and artifacts contain only Zig. C remains isolated test/reference infrastructure.

## Prohibited shortcuts

- reduced handwritten grammar instead of Lemon;
- substitute algorithms chosen to pass fixtures;
- linked or wrapped SQLite C behavior;
- counting hybrid, oracle, symbol, layout, hook, or finite-corpus evidence as completion;
- dropping active behavior because its C transport is excluded.
