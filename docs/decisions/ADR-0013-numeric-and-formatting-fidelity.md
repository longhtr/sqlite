# ADR-0013: Preserve numeric states and source formatter ownership

## Status

Accepted for the numeric and formatter foundation.

## Decision

Preserve SQLite integer parsing across UTF encodings, decimal/hex statuses, 32-bit boundaries, `sqlite3AtoF` lexical/truncation/overflow/underflow behavior, and exact binary64 output.

Preserve formatter metadata, `StrAccum`, `RCStr`, Mem-backed argument consumption, typed integer/radix/string/escape/floating/count/width/precision behavior, `%z` ownership, SQL adaptation, and allocation/failure semantics. libc formatting is not a final implementation. Connection/Parse/Expr/SrcItem ownership and public logging/configuration remain separate integration work.

## Consequences

Numeric conversion changes require exact-bit evidence. Formatter changes require language, ownership, OOM, caller, and differential evidence under `docs/TESTING.md`; volatile observation counts do not belong in this ADR.
