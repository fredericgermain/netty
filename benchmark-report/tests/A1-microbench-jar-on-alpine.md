# A1. Baseline: does netty's shaded microbench jar run at all on Alpine

**Confidence:** SOLID
**Date:** fixes landed on or before 2026-08-20 (matrix harness commits `d87055ae33` .. `df56c5881c`); the
verifying matrix run is 2026-08-25; the enumeration below was re-derived from the branch diffs on
2026-11-18
**Question:** can netty's own `microbench` shaded jar run the SSL benchmarks unmodified, on Alpine and
elsewhere?

## Configuration

Netty 4.2.18-SNAPSHOT, `microbench` module built with `-Pbenchmark-jar` inside netty's own
centos-7.111 docker-compose shell (see `benchmark-report/scripts/thor-x86.sh`). Images exercised
afterwards: `eclipse-temurin:21-jdk`, `eclipse-temurin:21-jdk-alpine`, `amazoncorretto:21-alpine`.
Not a timed benchmark -- this is a does-it-run result.

## Result

**No**, not until fixed. Four distinct defects in upstream netty's `microbench` SSL benchmarks, fixed
in three commits on this branch. Each one is readable in the diff; the table gives the pre-fix line
that carried the defect and the post-fix line that replaced it.

| # | Defect | Fixed by | Pre-fix | Post-fix |
|---|---|---|---|---|
| 1 | Key material resolved with `new File(getClass().getResource(...).getFile())`, which inside a jar yields `file:/....jar!/io/netty/...` -- not a filesystem path | `a73e536c05` | `AbstractSslEngineBenchmark.java:75-76`, `AbstractSslHandlerBenchmark.java:76-77` | `...Engine...:134-135`, `...Handler...:110-111`, both via `getResourceAsStream` and `SslContextBuilder.forServer(InputStream, InputStream)` |
| 2 | `SslContext` held in enum **field initialisers**, so `<clinit>` built all three providers' contexts and `OpenSsl.ensureAvailability()` ran even for a JDK-provider row | `eccd312033` | `AbstractSslEngineBenchmark.java:59-60`, `AbstractSslHandlerBenchmark.java:60-61` (`private final SslContext clientContext = newClientContext();`) | `...Engine...:80,87` and `...Handler...:80,87`, `synchronized` accessors built on first use from `@Setup` |
| 3 | `configureEngine()` pinned `setEnabledProtocols(new String[]{ PROTOCOL_TLS_V1_2 })`, so TLS 1.3 was never benchmarked on any provider | `ddd22b8641` | `AbstractSslEngineBenchmark.java:121`, `AbstractSslHandlerBenchmark.java:126` | `...Engine...:162`, `...Handler...:138`, protocol derived from the suite by `protocolOf()` (`:48` in both) |
| 4 | Handshake driver ran both engines in lock step to a `FINISHED` flag, and reused handshake buffers across invocations -- both latent, both only reachable once TLS 1.3 was enabled | `ddd22b8641` | `AbstractSslEngineBenchmark.java` `isHandshakeFinished()` and the `do/while (!clientHandshakeFinished \|\| !serverHandshakeFinished)` loop | `...Engine...:338` `isHandshaking()` / `wants()`, driven by `HandshakeStatus`; buffers cleared per invocation at `:278` |

Defect 4 is two faults with one trigger, which is why the count is four and the commits are three. In
TLS 1.3 the client reports `FINISHED` as soon as it has unwrapped the server's Finished while it
still has its own Finished to send, so a finished-flag loop skips that wrap and the server never
completes. Separately, TLS 1.3 sends NewSessionTicket *after* the handshake proper; those bytes left
in `sTOc` are read by the next invocation's fresh client engine as the start of a new stream. Both
present as `SSLException: Unrecognized SSL message, plaintext connection?`. The handler benchmarks
needed neither fix -- they drive their handshake through `SslHandler` on an `EmbeddedChannel`.

A fourth commit, `34c69ad8f2`, is not a bug fix: it adds `-Dnetty.bench.tls.groups` via
`OpenSslContextOption.GROUPS` so the key exchange group can be pinned. That is [A5](A5-key-exchange-group-sweep.md)'s
subject, and it is what showed the uncontrolled TLS 1.2-vs-1.3 comparison to be half post-quantum
group and half protocol version.

None of the four is upstream: `git branch -a --contains` puts all four commits on `thermal-report`
and `fg/thermal-report` only. Nothing in netty's CI would have caught any of them, because nothing
in netty's CI runs `microbench`.

## Reading

Establishes that the shaded microbench jar was broken for SSL work before this branch, in four
independent ways, and that all four defects are in code still present upstream.

What this rests on, precisely: the **defects and their fixes are verified from the diffs**, which is
stronger evidence than a log -- the failing expression is readable at a named line. The **pre-fix
stack traces are quoted from the commit messages**, written the same day by the author who
reproduced them; no archived JMH output shows a pre-fix failure.
`benchmark-report/logs/x86run.log` shows only post-fix behaviour, and corroborates defects 2 and 3
independently:

- defect 2: on `eclipse-temurin:21-jdk-alpine / none` and `amazoncorretto:21-alpine / none`, where
  tcnative is absent, the JDK-provider rows still produce results (`results : 2`)
- defect 3: every passing cell reports a `TLS_AES_128_GCM_SHA256` row, so TLS 1.3 is genuinely being
  benchmarked

Defects 1 and 4 are not separately observable in the committed output -- a run that cannot build a
context and a run whose buffers desynchronise both just produce no results.

## Raw data

- Branch history, `microbench/src/main/java/io/netty/microbench/handler/ssl/`: `a73e536c05`
  (streams), `eccd312033` (lazy contexts), `ddd22b8641` (TLS 1.3 + handshake driver + buffer
  clearing), `34c69ad8f2` (groups). Each commit message carries the pre-fix stack trace or exception
  it was written against, and the verifying numbers.
- `benchmark-report/logs/x86run.log` -- post-fix matrix run, both released and patched tcnative
- `benchmark-report/logs/reactor.log` -- the `microbench` jar build, `BUILD SUCCESS`, finished
  2026-08-25T12:41:21Z
- `benchmark-report/logs/jar-released.log`, `jar-patched.log`, `jar-openssl.log` -- the three
  flavour builds, all `BUILD SUCCESS`
- `benchmark-report/scripts/thor-x86.sh` -- the build and run driver

## Caveats

- Line numbers are against `thermal-report` at `926a2349dc`. Pre-fix numbers are against each
  commit's parent; re-derive with `git show <commit>` rather than trusting them after a rebase.
- No archived output shows a pre-fix failure. If the pre-fix behaviour itself has to be published,
  check out `a73e536c05^` and capture a run.
- Only `SslEngineHandshakeBenchmark` was ever exercised in the matrix. `SslEngineEchoBenchmark`,
  `SslEngineWrapBenchmark` and `SslHandlerEchoBenchmark` share the fixed code paths but were not run
  here, and may still be broken in ways these four fixes do not cover.
- x86_64 only for the committed evidence.

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- what the fixed jar then found on Alpine
- [A5](A5-key-exchange-group-sweep.md) -- the group option added by the fifth commit
- [A8](A8-negative-controls.md) -- the controls that prove a passing cell is really passing
- [A10](A10-patched-tcnative-matrix-gate.md) -- the same jar against patched tcnative
