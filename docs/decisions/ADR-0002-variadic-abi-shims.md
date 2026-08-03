# ADR-0002: C-only variadic ABI shims

## Status

Superseded by ADR-0040.

## Historical decision

The earlier drop-in C ABI plan allowed tiny C shims to unpack variadic arguments and call Zig. A target-specific probe validated representative argument shapes.

## Reason for supersession

The product is now a Zig-native source-faithful port, not a C ABI replacement. Variadic transport is represented by typed Zig unions or argument slices, and production artifacts contain no C objects. The old probe and shim remain test-only bounded evidence.
