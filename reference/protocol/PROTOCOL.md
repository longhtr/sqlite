# Differential Worker Protocol v1

Workers run in separate processes. Requests and responses are newline-delimited UTF-8 fields separated by tabs. Version 1 Phase 0 supports metadata only:

```text
HELLO\t1             -> OK\t1\t<engine>
VERSION             -> VERSION\t<text>\t<number>\t<threadsafe>\t<source-id>
QUIT                -> BYE
```

Unknown or malformed requests return `ERROR\t<stable-classification>` without terminating the worker. Future SQL/API operations must encode lengths explicitly and preserve typed NULL/integer/float/text/blob values; they must not reuse diagnostic strings as normative values.
