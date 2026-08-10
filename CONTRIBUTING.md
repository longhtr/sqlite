# Contributing

Before coding, read `docs/PORTING_CHARTER.md`, `docs/SCOPE.md`, and `docs/ENGINEERING_PROCESS.md`. Select one dependency-closed atomic unit from `docs/EXECUTION_PLAN.md` and complete its source/context, ownership, failure, integration, and evidence dossier.

A patch must:

- translate pinned canonical source before refactoring;
- preserve control flow, state, allocation/failure, cleanup, callback/lock/I/O order, results, and continuation;
- keep C in isolated oracle/test infrastructure;
- use bounded workers and neutral C/Zig protocols where applicable;
- retire or quarantine duplicate production owners when integrating;
- run focused checks during implementation and broad gates only at promotion or requested handoff;
- claim only the evidence state actually reached.

Detailed gates and reporting rules live only in `docs/ENGINEERING_PROCESS.md`; this file intentionally does not duplicate them.
