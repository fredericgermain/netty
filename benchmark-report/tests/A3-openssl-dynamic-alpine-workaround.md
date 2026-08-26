# A3. openssl-dynamic as an Alpine workaround

**Confidence:** SOLID
**Date:** 2026-08-25 (gate run in `x86run.log`; insight run 2026-08-25T13:03:00Z and 13:09:12Z)
**Question:** if `boringssl-static` will not load on Alpine, does the `openssl-dynamic` flavour of the
same released tcnative load instead?

## Configuration

Released `netty-tcnative` (openssl-dynamic) 2.0.81, classifier `linux-x86_64`, shaded into the fixed
microbench jar (`mb-openssl.jar`, built by `benchmark-report/scripts/thor-x86.sh` step 3/3). Images:
`eclipse-temurin:21-jdk` (glibc), `eclipse-temurin:21-jdk-alpine`, `amazoncorretto:21-alpine`. The
Alpine images need `apr` and `openssl` packages present. Gate mode `-f 1 -wi 1 -i 2` in `x86run.log`;
insight mode `-f 3 -wi 5 -i 10` in `insight.log` and the JSONL records.

## Result

Loads on Alpine x86_64 on released 2.0.81 and reports **OpenSSL 3.5.7 9 Jun 2026**. No
`linux-aarch_64` classifier is published for `openssl-dynamic`, so this workaround is x86_64 only.

From `x86run.log`, released tcnative, all three images on the `openssl` flavour:

| image | verdict | tcnativeVersion |
|---|---|---|
| eclipse-temurin:21-jdk | PASS | OpenSSL 3.5.5 27 Jan 2026 |
| eclipse-temurin:21-jdk-alpine | PASS | OpenSSL 3.5.7 9 Jun 2026 |
| amazoncorretto:21-alpine | PASS | OpenSSL 3.5.7 9 Jun 2026 |

All three report `results : 4`, meaning both the JDK and the OPENSSL provider rows ran.

**Upgraded from RECALLED to SOLID.** Verified by `benchmark-report/logs/x86run.log` (three PASS
verdicts and the version strings) and by the committed JMH records under `benchmark-report/jmh/`,
whose `tcnativeVersion` fields carry the same strings.

## Reading

Establishes that a working tcnative path on Alpine exists today, on the released artifact, with no
patching -- and that nobody documents it. The flavour most people reach for first
(`boringssl-static`) is the broken one.

Does **not** establish that this workaround is a good idea. `openssl-dynamic` resolves the distro's
libssl at runtime, and [A4](A4-libc-effect-by-tcnative-flavour.md) shows that flavour carries a
handshake cost that `boringssl-static` does not.

Does **not** establish anything about aarch64, because no `linux-aarch_64` classifier is published to
test. That absence is a packaging fact, corroborated by the comment in
`benchmark-report/scripts/thor-x86.sh` ("x86_64 only -- no linux-aarch_64 classifier exists"), not by
a failed run.

## Raw data

- `benchmark-report/logs/x86run.log` -- three PASS cells with version strings
- `benchmark-report/logs/insight.log` -- the insight-mode re-run
- `benchmark-report/jmh/insight/*.jsonl` -- tagged JMH records carrying `tcnativeVersion`
- `benchmark-report/logs/jar-openssl.log` -- the jar build, `BUILD SUCCESS`, finished
  2026-08-25T12:42:19Z
- `benchmark-report/scripts/thor-x86.sh`, `benchmark-report/scripts/thor-insight.sh`

## Caveats

- x86_64 only, and not by choice.
- The `apr` and `openssl` package requirement is a recalled deployment detail. No committed log shows
  the failure that happens without them.
- **The glibc and musl images do not carry the same OpenSSL.** glibc reports 3.5.5, both Alpine
  images report 3.5.7. That is fine for "does it load" but it is a confound for any cross-libc
  performance comparison -- see [A4](A4-libc-effect-by-tcnative-flavour.md).
- One tcnative version (2.0.81).

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- the flavour that fails
- [A4](A4-libc-effect-by-tcnative-flavour.md) -- what this flavour costs
- [A10](A10-patched-tcnative-matrix-gate.md) -- the patched `boringssl-static` that removes the need
  for a workaround
