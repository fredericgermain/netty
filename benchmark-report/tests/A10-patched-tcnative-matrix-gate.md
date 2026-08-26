# A10. Patched tcnative 2.0.82-SNAPSHOT clears the matrix on Alpine

**Confidence:** SOLID
**Date:** 2026-08-25; the patched jar build finished 2026-08-25T12:42:37Z
**Question:** does `boringssl-static` built from the patched 2.0.82.Final-SNAPSHOT actually load and
run on both Alpine images, where released 2.0.81 fails?

**This test was not in the catalogue.** It was recovered by reading `x86run.log`, which
`TESTS.md` had listed as "not re-read".

## Configuration

Driver `benchmark-report/scripts/thor-x86.sh`, second half
(`############ matrix: PATCHED tcnative, all three images`).

- Jar: `mb-patched.jar`, `microbench` built with `-Pbenchmark-jar,boringssl-snapshot`,
  `-Dtcnative.classifier=linux-x86_64`, resolving
  `io.netty:netty-tcnative-boringssl-static:2.0.82.Final-SNAPSHOT` (confirmed in `jar-patched.log`)
- Harness: `.github/scripts/tls-matrix/matrix.sh --jar-boringssl mb-patched.jar`
- Mode: **gate**, `-f 1 -wi 1 -i 2`
- Images: `eclipse-temurin:21-jdk` (glibc), `eclipse-temurin:21-jdk-alpine`,
  `amazoncorretto:21-alpine`
- Six cells run, three skipped (`openssl` flavour, no patched jar built for it)
- No CPU pinning

## Result

**6 passed, 0 failed. `PATCHED_EXIT=0`.** Both Alpine `boringssl` cells now report
`tcnativeVersion=BoringSSL` and `results : 4`.

Against the released run in the same log: **7 passed, 2 failed, `RELEASED_EXIT=1`**, the two failures
being exactly the Alpine `boringssl` cells.

Gate-mode scores, `us/op`, `Cnt 2`, **no error bars**:

| build | image | libc | provider / cipher | score |
|---|---|---|---|---|
| patched boringssl | eclipse-temurin:21-jdk | glibc | OPENSSL TLS 1.2 | 762.303 |
| patched boringssl | eclipse-temurin:21-jdk | glibc | OPENSSL TLS 1.3 | 1387.226 |
| patched boringssl | eclipse-temurin:21-jdk-alpine | musl | OPENSSL TLS 1.2 | 807.641 |
| patched boringssl | eclipse-temurin:21-jdk-alpine | musl | OPENSSL TLS 1.3 | 1459.042 |
| patched boringssl | amazoncorretto:21-alpine | musl | OPENSSL TLS 1.2 | 781.079 |
| patched boringssl | amazoncorretto:21-alpine | musl | OPENSSL TLS 1.3 | 1457.244 |
| released boringssl | eclipse-temurin:21-jdk | glibc | OPENSSL TLS 1.2 | 767.251 |
| released boringssl | eclipse-temurin:21-jdk | glibc | OPENSSL TLS 1.3 | 1392.203 |
| released openssl | eclipse-temurin:21-jdk | glibc | OPENSSL TLS 1.2 | 992.576 |
| released openssl | eclipse-temurin:21-jdk-alpine | musl | OPENSSL TLS 1.2 | 1238.371 |
| released openssl | amazoncorretto:21-alpine | musl | OPENSSL TLS 1.2 | 1197.104 |

## Reading

Establishes the payoff of the whole tcnative thread: the patched build turns two hard failures into
two passes, and does it without changing the glibc numbers (762.303 patched against 767.251 released,
well inside gate-mode noise). The fix does not cost glibc users anything measurable.

Also establishes that the patched build's musl scores land close to its glibc scores (807.6 and 781.1
against 762.3 on TLS 1.2), consistent with [A4](A4-libc-effect-by-tcnative-flavour.md)'s insight-mode
finding that `boringssl-static` has no libc effect. Two independent runs, two JMH configurations, same
conclusion.

Does **not** establish anything publishable about *how fast* the patched build is. Gate mode is
`-f 1 -wi 1 -i 2` with no error bars at all -- the `Cnt 2` column and the missing Error column say so.
Use [A4](A4-libc-effect-by-tcnative-flavour.md)'s insight numbers for any quoted figure. The gate
scores above are recorded for provenance, not for citation.

Does **not** cover aarch64. The `openssl` flavour was skipped in the patched half because no patched
jar was built for it, so this run says nothing about `openssl-dynamic` under the patch.

## Raw data

- `benchmark-report/logs/x86run.log`, from `############ matrix: PATCHED tcnative, all three images`
  to `ALL_DONE`
- `benchmark-report/logs/jar-patched.log` -- `BUILD SUCCESS`, finished 2026-08-25T12:42:37Z, and the
  lines `Including io.netty:netty-tcnative-boringssl-static:jar:linux-x86_64:2.0.82.Final-SNAPSHOT in
  the shaded jar`
- `benchmark-report/scripts/thor-x86.sh`

**Provenance oddity worth recording:** `jar-released.log` finished at 2026-08-25T13:42:09Z, an hour
*after* `jar-patched.log` (12:42:37Z) and `jar-openssl.log` (12:42:19Z), and after the matrix run
itself. `thor-x86.sh` builds released first, so the released log in this branch is from a later,
separate rebuild and is not the build that produced the `mb-released.jar` used in `x86run.log`. The
build is deterministic enough that this is unlikely to matter, but the log is not the one.

## Caveats

- Gate mode. Two measurement iterations, one fork, one warm-up iteration. No spreads.
- x86_64 only.
- `2.0.82.Final-SNAPSHOT` is a snapshot, not a release. Its contents can change under the same
  coordinate.
- The `openssl-dynamic` flavour is untested under the patch (skipped, no jar).
- Three images, one cipher per protocol version, `bufferType=DIRECT` only.

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- the failure this fixes
- [A4](A4-libc-effect-by-tcnative-flavour.md) -- the insight-mode numbers to quote instead
- [A8](A8-negative-controls.md) -- the controls that make the 6/6 pass meaningful
- [B](B-quic-musl-fix.md) -- the same upstream approach ported to `codec-native-quic`
