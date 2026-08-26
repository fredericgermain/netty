# A2. tcnative 2.0.81 on Alpine, both architectures

**Confidence:** SOLID, RECALLED
**Date:** 2026-08-25 (matrix run in `x86run.log`); the aarch64 observations predate it and are undated
**Question:** does released `netty-tcnative-boringssl-static` 2.0.81 load on Alpine/musl, and does the
failure look the same on x86_64 and aarch64?

## Configuration

Released `netty-tcnative-boringssl-static` 2.0.81, shaded into the fixed microbench jar
(`mb-released.jar`), run by `.github/scripts/tls-matrix/matrix.sh` in **gate** mode
(`-f 1 -wi 1 -i 2`). Images: `eclipse-temurin:21-jdk` (glibc control),
`eclipse-temurin:21-jdk-alpine` and `amazoncorretto:21-alpine` (musl). Native execution on thor
(x86_64), not emulated. The aarch64 arm was run natively on aarch64 hardware; that run produced no
log that survives in this branch.

## Result

- **x86_64: `library-load` failure.** Catchable `UnsatisfiedLinkError`;
  `ld-linux-x86-64.so.2` sits unresolved in `DT_NEEDED`.
- **aarch64: `jvm-crash`.** Uncatchable SIGSEGV in `JVM_LoadLibrary`, via libgcc's outline-atomics
  probe `init_have_lse_atomics` calling `__getauxval` from an `.init_array` constructor during
  `dlopen`. musl does not export `__getauxval`.

What `x86run.log` shows verbatim for both musl images on the `boringssl` flavour:

```
tcnativeVersion=unavailable: java.lang.IllegalArgumentException: Failed to load any of the given
libraries: [netty_tcnative_linux_x86_64, netty_tcnative_linux_x86_64_fedora,
netty_tcnative_x86_64, netty_tcnative]
...
tls-matrix: FAIL on eclipse-temurin:21-jdk-alpine / boringssl
tls-matrix: FAIL on amazoncorretto:21-alpine / boringssl
```

Released-tcnative matrix totals: **passed 7, failed 2**, and the two failures are exactly the two
Alpine `boringssl` cells. The glibc `boringssl` cell passes with `tcnative : BoringSSL`.

## Reading

Establishes, from committed output, that released 2.0.81 `boringssl-static` **does not load on either
Alpine image on x86_64**, and that the failure is survivable: the JVM continued and still produced
the two JDK-provider rows. That is the definition of a catchable load failure.

Does **not** establish, from committed output:

- the `ld-linux-x86-64.so.2` / `DT_NEEDED` mechanism. The string `ld-linux` does not appear anywhere
  in `x86run.log`. The mechanism is recalled from an `readelf`/`ldd` inspection whose output was not
  kept.
- anything at all about aarch64. `x86run.log` is x86_64 only. The `jvm-crash` verdict,
  `init_have_lse_atomics`, `__getauxval` and the `.init_array` timing are entirely recalled.

The architecture asymmetry is the point of the test and it is the half that is least well evidenced.
Re-run the aarch64 arm and keep the log before publishing the severity claim.

## Raw data

- `benchmark-report/logs/x86run.log`, section `############ matrix: RELEASED tcnative, all three
  images` -- x86_64 evidence
- `benchmark-report/scripts/thor-x86.sh` -- the driver
- `.github/scripts/tls-matrix/matrix.sh`, `run.sh` -- the harness
- **Missing:** any aarch64 run log; any `readelf -d` output showing the `DT_NEEDED` entry.

## Caveats

- Gate mode is `-f 1 -wi 1 -i 2`. It is a pass/fail instrument. No score from this run should be
  quoted with confidence.
- One tcnative version (2.0.81), one BoringSSL flavour, three images.
- The musl reserved-name mechanism (`ldso/dynlink.c`, `reserved[] = "c.pthread.rt.m.dl.util.xnet."`)
  quoted in `FINDINGS.md` is a source reading, not a measurement.

## Related

- [A3](A3-openssl-dynamic-alpine-workaround.md) -- the flavour that does load on Alpine
- [A8](A8-negative-controls.md) -- why the FAIL is a real failure and not a mislabelled pass
- [A10](A10-patched-tcnative-matrix-gate.md) -- the patched build that fixes this
- [B](B-quic-musl-fix.md) -- the same class of musl problem in `codec-native-quic`
