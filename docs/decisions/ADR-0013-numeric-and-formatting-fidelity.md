# ADR-0013: Preserve numeric parsing states and bound the formatter evidence

## Status

Accepted for the numeric utility slice.

## Decision

The native numeric slice preserves SQLite integer parsing for UTF-8, UTF-16LE, and UTF-16BE; decimal and hexadecimal statuses; signed and unsigned 32-bit boundaries; and `sqlite3AtoF` lexical state, truncation, overflow, underflow, malformed suffixes, and binary64 output.

Zig's correctly rounded conversion of the same truncated rational represents SQLite's compiler-workaround power tables. Exact-bit oracle evidence is mandatory.

The exact conversion identities, 23-entry metadata table, hash links, digit/prefix bytes, selected profile limits, source-corresponding `StrAccum` state machine, `RCStr` ownership lifecycle, and exact Mem-backed `PrintfArguments` cursor are ported as the formatter foundation. The complete renderer has focused differential evidence, and the Zig-native typed implementation covers integers, radix, ordinal, pointers, strings, ownership-transferring `%z`, characters, `%q`/`%Q`/`%w`, floating conversions, percent, count, width, and precision. Typed `%T`/`%S` output, the exact Mem-backed SQL argument adapter, and typed allocation/fixed/logging callers are connected; error-offset semantics are ported through typed views; exact Parse/Expr/SrcItem adoption, owner wiring and connection allocator/OOM integration remain open. Typed global log dispatch is connected; its configuration lifecycle, races, and reentrancy remain open.

## Evidence

All 77 active `printf.c` entities now have focused source mappings and differential evidence; this does not yet constitute final fidelity review.

- `zig build numeric-differential` compares boundary and seeded integer/float traces with exact binary64 bits.
- Native tests cover statuses, UTF-16, hexadecimal behavior, floating lexical states, and signed extrema.
- A 282-observation compiled-C differential checks formatter constants, every metadata row, and all 256 byte lookup outcomes.
- Exact C/Zig `StrAccum` layout and eleven states plus native one-shot/sticky OOM tests check fixed/dynamic growth, truncation, finish reallocation, limits, reset, and error persistence.
- Exact `RCStr` layout and six lifecycle observations plus failed-resize fault tests check reference and ownership semantics.
- Exact `PrintfArguments` layout and seven consumption/default observations check integer, double, text, exhaustion, and cursor semantics.
- 298 compiled-C/Zig observations check exact `FpDecode` layout, multiplication/scaling, binary/decimal conversion, boundaries, specials, rounding, and seeded binary64 patterns.
- Ninety-eight compiled-C/Zig observations check typed public/internal integer/string/floating rendering, UTF-8 width/precision, dynamic fields, count, temporary allocation, `%z` ownership, Token/SrcItem output, and seeded binary64 formats; native tests cover rendering OOM and limits.
- Eight compiled-C/Zig SQL-function/result observations check exact Mem conversions, missing defaults, consumption, borrowed `%z`, ignored `%n`, dynamic width/precision, and StrAccum result error/empty/dynamic ownership.
- Eight caller observations check allocated/empty strings, fixed truncation, zero capacity, internal formatting, and synchronous logging; native one-shot/sticky tests cover finish OOM.
- Five dynamic-string-object observations check construction, limits, value, finish ownership, and errors; native faults cover the sticky OOM singleton and no-op destruction.
- Ten error-offset observations check exclusive token ranges, first-error persistence, null state, expression traversal, join origins, and DDL suppression.
- Relationships are recorded in `upstream/symbol-map.json`.

## Consequences

Changes to floating conversion rerun the exact-bit corpus. Formatter expansion requires source mappings and dedicated language, ownership, OOM, and differential evidence. libc formatting is not an accepted final implementation.
