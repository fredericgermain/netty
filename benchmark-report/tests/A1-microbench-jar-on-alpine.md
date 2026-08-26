# A1. Baseline: does netty's shaded microbench jar run at all on Alpine

**Confidence:** SOLID, RECALLED
**Date:** fixes landed on or before 2026-08-20 (matrix harness commits `d87055ae33` .. `df56c5881c`); the
verifying matrix run is 2026-08-25
**Question:** can netty's own `microbench` shaded jar run the SSL benchmarks unmodified, on Alpine and
elsewhere?

## Configuration

Netty 4.2.18-SNAPSHOT, `microbench` module built with `-Pbenchmark-jar` inside netty's own
centos-7.111 docker-compose shell (see `benchmark-report/scripts/thor-x86.sh`). Images exercised
afterwards: `eclipse-temurin:21-jdk`, `eclipse-temurin:21-jdk-alpine`, `amazoncorretto:21-alpine`.
Not a timed benchmark -- this is a does-it-run result.

## Result

**No**, not until fixed. The SSL benchmarks could not initialise because key material was resolved
with `getResource().getFile()`, which fails inside a jar. Four distinct upstream microbench bugs were
found and fixed on this branch:

1. resource loading via `getFile()`
2. SSL contexts built eagerly for every provider, so JDK rows could not run where tcnative was absent
3. `AbstractSslEngineBenchmark.configureEngine()` hardcoded `PROTOCOL_TLS_V1_2`, so TLS 1.3 was never
   benchmarked on any provider
4. handshake driver needed to be status-driven, with per-invocation buffer clearing

## Reading

Establishes that the shaded microbench jar was broken for SSL work before this branch, and that
nothing in netty's CI would have caught it because nothing in netty's CI runs `microbench`.

What it does **not** establish: the enumeration above reached this document through a conversation
summary. No committed artifact shows the *pre-fix* failure. `benchmark-report/logs/x86run.log` shows
only the post-fix behaviour.

The post-fix behaviour is verifiable and does corroborate fixes 2 and 3:

- fix 2: on `eclipse-temurin:21-jdk-alpine / none` and `amazoncorretto:21-alpine / none`, where
  tcnative is absent, the JDK-provider rows still produce results (`results : 2`)
- fix 3: every passing cell reports a `TLS_AES_128_GCM_SHA256` row, so TLS 1.3 is genuinely being
  benchmarked

Fixes 1 and 4 are not separately observable in the committed output.

## Raw data

- `benchmark-report/logs/x86run.log` -- post-fix matrix run, both released and patched tcnative
- `benchmark-report/logs/reactor.log` -- the `microbench` jar build, `BUILD SUCCESS`, finished
  2026-08-25T12:41:21Z
- `benchmark-report/logs/jar-released.log`, `jar-patched.log`, `jar-openssl.log` -- the three
  flavour builds, all `BUILD SUCCESS`
- `benchmark-report/scripts/thor-x86.sh` -- the build and run driver
- Source of the fixes: this branch's history under
  `microbench/src/main/java/io/netty/microbench/handler/ssl/`. **Exact file and line references were
  never recorded in this catalogue** and are not in any committed log.

## Caveats

- The four-bug list is recalled, not read back from a diff. Re-derive it from the branch history
  before publishing it as a list.
- Only `SslEngineHandshakeBenchmark` was ever exercised. Other microbench benchmarks may still be
  broken in the same ways.
- x86_64 only for the committed evidence.

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- what the fixed jar then found on Alpine
- [A8](A8-negative-controls.md) -- the controls that prove a passing cell is really passing
- [A10](A10-patched-tcnative-matrix-gate.md) -- the same jar against patched tcnative
