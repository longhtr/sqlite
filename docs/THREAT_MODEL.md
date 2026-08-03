# Threat Model

## Untrusted inputs

- SQL text, parameters, Zig callbacks, collations, modules, and API sequences.
- Database, journal, WAL, and transient WAL-index files.
- VFS responses, short operations, I/O errors, disk-full conditions, clocks, and randomness.
- Concurrent threads/processes and abrupt termination.

## Protected properties

- Memory and type safety.
- No corruption or lost acknowledged commit inside a declared durability profile.
- Bounded CPU, memory, stack, parser, and VDBE work under configured limits.
- Correct callback/module lifetimes and no unintended native code loading.
- No fidelity or safety claim outside an evidence-backed profile.
- No C implementation code in production artifacts.
- Test/oracle workers cannot exhaust host memory, output storage, process slots, or execution time.

## Trust boundaries

The C oracle and C diagnostic workers are isolated test infrastructure and do not share private state with the Zig engine. Repository tools and build-run artifacts now use the centrally verified time, output, process-group RSS/address-space, file, CPU, process, descriptor, argument, and input limits in `tools/bounded_subprocess.py`; failures kill descendants and preserve bounded artifacts. Test databases are copied before destructive fault/recovery work. Failure artifacts are preserved before recovery mutates them. Zig-native modules are untrusted application code and are disabled or explicitly registered according to the final API policy.
