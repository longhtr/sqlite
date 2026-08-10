# ADR-0005: Independent bounded durability model

## Status

Accepted as bounded simulator/oracle evidence for the DELETE/FULL model; ADR-0041 prohibits extending it as substitute production architecture.

## Decision

Validate source-translated rollback and WAL protocols against an independent durable/volatile model, named I/O events, crash exploration, mutation tests, and physical-system profiles. Claims are limited to explicit journal/synchronous/device/filesystem combinations. Reduced models receive no subsystem-integration credit.

## Consequences

Storage porting stops if the model cannot reproduce selected source traces or detect curated ordering mutants. `docs/DURABILITY_MODEL.md` owns the modeled protocol and open matrix; `docs/TESTING.md` owns commands and result modules.
