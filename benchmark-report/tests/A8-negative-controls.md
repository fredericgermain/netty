# A8. Cross-checks that were run as negative controls

**Confidence:** SOLID
**Date:** 2026-08-25 (the run recorded in `x86run.log`)
**Question:** when a matrix cell reports a number, is there anything that would have caught it
reporting the wrong library's number, or reporting a number at all when it should have failed?

## Configuration

Two controls built into `.github/scripts/tls-matrix/run.sh` and exercised by the full matrix run in
`benchmark-report/scripts/thor-x86.sh`:

1. **Result-count assertion.** `--expect 4` for a cell that should produce four rows
   (`sslProvider=JDK,OPENSSL` x two ciphers). Fewer means the OPENSSL rows failed to initialise.
2. **Provider identity cross-check.** The harness reads `SSL.versionString()` and compares it against
   the tcnative flavour the cell requested.

Gate mode, `-f 1 -wi 1 -i 2`, three images, three flavours.

## Result

Both behaved correctly. Verbatim from `benchmark-report/logs/x86run.log`, on
`eclipse-temurin:21-jdk-alpine / boringssl` with released 2.0.81:

```
   results   : 2
   FAIL: expected at least 4 benchmark result(s), got 2 -- JMH exits 0 even when every benchmark
   fails to initialize, so check the run log
   FAIL: tcnative was requested as 'boringssl' but the image reports: unavailable:
   java.lang.IllegalArgumentException: Failed to load any of the given libraries: [...]
tls-matrix: FAIL on eclipse-temurin:21-jdk-alpine / boringssl
```

The identical pair of FAILs fires on `amazoncorretto:21-alpine / boringssl`. The released matrix
exits `RELEASED_EXIT=1` with `passed : 7, failed : 2`.

The identity check also passes positively where it should: cells that requested `boringssl` report
`tcnative : BoringSSL`, and cells that requested `openssl` report `tcnative : OpenSSL 3.5.5 27 Jan
2026` or `OpenSSL 3.5.7 9 Jun 2026`. A cell labelled BoringSSL really is BoringSSL.

**Upgraded from RECALLED to SOLID.** Verified against `benchmark-report/logs/x86run.log`, which
carries both FAIL messages verbatim and the passing identity strings.

## Reading

Establishes that the matrix cannot silently report a JDK-provider number under a tcnative label, and
cannot report a green run with an empty result array. The second is the more valuable control: JMH
exits 0 when every benchmark fails to initialise, so a CI script checking the exit code alone would
have called the released-2.0.81-on-Alpine run a pass.

Does **not** establish that the *scores* are correct, only that the right library produced them. No
control cross-checks a handshake count or compares against an independent implementation.

Does **not** cover the aarch64 crash path. A JVM that dies during `dlopen` never reaches either
assertion; the harness catches that as a missing result file, not as one of these two FAILs.

## Raw data

- `benchmark-report/logs/x86run.log` -- both FAIL messages, and the passing identity strings on every
  other cell
- `.github/scripts/tls-matrix/run.sh` -- where `--expect` and the version cross-check are implemented
- `benchmark-report/scripts/thor-x86.sh`

## Caveats

- Gate mode only. These are pass/fail controls; they say nothing about measurement quality.
- x86_64 only.
- The controls test the *harness*, not netty. A netty bug that produced a plausible wrong number
  would pass both.

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- the failure these controls caught
- [A1](A1-microbench-jar-on-alpine.md) -- the empty-result-array trap these were written for
- [A10](A10-patched-tcnative-matrix-gate.md) -- the same controls on the patched build, all passing
