# A4. libc effect on handshake cost, by tcnative flavour

**Confidence:** SOLID
**Date:** 2026-08-25, 12:56:48Z .. 13:27:47Z (six JMH runs, timestamps in the JSONL records)
**Question:** is the musl handshake penalty a property of musl, or a property of one tcnative
flavour?

## Configuration

Insight mode, x86_64, idle host (thor). Driver `benchmark-report/scripts/thor-insight.sh` calling
`.github/scripts/tls-matrix/run.sh`.

- JMH: `-f 3 -wi 5 -i 10` (three forks, five warm-up iterations, ten measurement iterations), mode
  `avgt`, benchmark `io.netty.microbench.handler.ssl.SslEngineHandshakeBenchmark.handshake`
- Parameters: `-p sslProvider=JDK,OPENSSL -p bufferType=DIRECT
  -p cipher=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_AES_128_GCM_SHA256`
- Flavours: `openssl-dynamic` 2.0.81 released (`mb-openssl.jar`), `boringssl-static`
  2.0.82.Final-SNAPSHOT patched (`mb-patched.jar`)
- Images: `eclipse-temurin:21-jdk` (glibc, JDK 21.0.12), `eclipse-temurin:21-jdk-alpine` (musl,
  JDK **21.0.11**), `amazoncorretto:21-alpine` (musl, JDK 21.0.12)
- No CPU pinning. This is a JMH microbenchmark, not a load test; neither cpuset applies.

## Result

TLS 1.2 (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`), us/op, lower is better:

| flavour / provider | glibc | musl |
|---|---|---|
| openssl-dynamic, OPENSSL | 990.4 +/- 19.8 | 1111.3 +/- 28.2 |
| boringssl-static, OPENSSL | 804.2 +/- 16.9 | 796.7 +/- 13.9 |
| JDK provider | control, no libc effect | control, no libc effect |

TLS 1.3 rows showed +17-22% for openssl-dynamic on musl.

Full values as recovered from `benchmark-report/jmh/`, all `us/op`, `forks 3`,
`measurementIterations 10`:

| image | libc | flavour | provider | cipher | score | error |
|---|---|---|---|---|---|---|
| eclipse-temurin:21-jdk | glibc | openssl | OPENSSL | TLS 1.2 | 990.443 | 19.797 |
| eclipse-temurin:21-jdk-alpine | musl | openssl | OPENSSL | TLS 1.2 | 1111.286 | 28.230 |
| amazoncorretto:21-alpine | musl | openssl | OPENSSL | TLS 1.2 | 1115.284 | 34.803 |
| eclipse-temurin:21-jdk | glibc | openssl | OPENSSL | TLS 1.3 | 1061.068 | 18.644 |
| eclipse-temurin:21-jdk-alpine | musl | openssl | OPENSSL | TLS 1.3 | 1240.616 | 39.776 |
| amazoncorretto:21-alpine | musl | openssl | OPENSSL | TLS 1.3 | 1298.154 | 25.984 |
| eclipse-temurin:21-jdk | glibc | boringssl | OPENSSL | TLS 1.2 | 804.152 | 16.892 |
| eclipse-temurin:21-jdk-alpine | musl | boringssl | OPENSSL | TLS 1.2 | 796.703 | 13.926 |
| amazoncorretto:21-alpine | musl | boringssl | OPENSSL | TLS 1.2 | 777.524 | 8.763 |
| eclipse-temurin:21-jdk | glibc | boringssl | OPENSSL | TLS 1.3 | 1346.328 | 11.070 |
| eclipse-temurin:21-jdk-alpine | musl | boringssl | OPENSSL | TLS 1.3 | 1352.852 | 17.574 |
| amazoncorretto:21-alpine | musl | boringssl | OPENSSL | TLS 1.3 | 1360.087 | 11.998 |

JDK-provider control rows, same runs:

| image | libc | flavour | cipher | score | error |
|---|---|---|---|---|---|
| eclipse-temurin:21-jdk | glibc | openssl | TLS 1.2 | 1935.486 | 37.901 |
| eclipse-temurin:21-jdk-alpine | musl | openssl | TLS 1.2 | 1925.208 | 35.670 |
| amazoncorretto:21-alpine | musl | openssl | TLS 1.2 | 1958.709 | 46.450 |
| eclipse-temurin:21-jdk | glibc | boringssl | TLS 1.2 | 2127.487 | 32.205 |
| eclipse-temurin:21-jdk-alpine | musl | boringssl | TLS 1.2 | 2073.231 | 59.978 |
| amazoncorretto:21-alpine | musl | boringssl | TLS 1.2 | 2021.425 | 76.698 |
| eclipse-temurin:21-jdk | glibc | boringssl | TLS 1.3 | 2472.646 | 124.783 |
| eclipse-temurin:21-jdk-alpine | musl | boringssl | TLS 1.3 | 2280.958 | 53.463 |
| amazoncorretto:21-alpine | musl | boringssl | TLS 1.3 | 2230.961 | 54.681 |

**Unit verified: `us/op`**, from the `"unit"` field of every JSONL record.

## Reading

Establishes that "musl is slower at TLS handshakes" is wrong as stated. `boringssl-static` shows no
libc effect at all -- on TLS 1.2 the musl numbers are if anything slightly *lower* (804.15 glibc
against 796.70 and 777.52 on the two musl images), and on TLS 1.3 the three images agree to within
1% (1346.33 / 1352.85 / 1360.09). The penalty belongs to the *dynamic* flavour: +12% on TLS 1.2,
+17% and +22% on TLS 1.3 across the two musl images.

The JDK control does its job: 1935.49 glibc against 1925.21 musl on the same run pair is no
difference.

The musl `openssl-dynamic` result **replicates on a second, independent musl image**: 1111.29 on
temurin-alpine and 1115.28 on amazoncorretto-alpine. That was not previously recorded and it
strengthens the finding considerably -- it is not one image's packaging.

Does **not** establish the mechanism. The story that runtime resolution of the distro libssl is what
costs the 12% was never instrumented.

## Raw data

- `benchmark-report/jmh/insight/eclipse-temurin-21-jdk__openssl__insight.jsonl`
- `benchmark-report/jmh/insight/eclipse-temurin-21-jdk-alpine__openssl__insight.jsonl`
- `benchmark-report/jmh/insight/amazoncorretto-21-alpine__openssl__insight.jsonl`
- `benchmark-report/jmh/insight-bssl/eclipse-temurin-21-jdk__boringssl__insight.jsonl`
- `benchmark-report/jmh/insight-bssl/eclipse-temurin-21-jdk-alpine__boringssl__insight.jsonl`
- `benchmark-report/jmh/insight-bssl/amazoncorretto-21-alpine__boringssl__insight.jsonl`
- `benchmark-report/logs/insight.log` -- the console transcript (TLS 1.3 OPENSSL rows only)
- `benchmark-report/scripts/thor-insight.sh`

**Upgraded from RECALLED to SOLID.** Every value in the headline table matches its JSONL record to
three decimals.

## Caveats

- **The openssl-dynamic glibc-vs-musl comparison is confounded by the OpenSSL version.** The glibc
  image resolves `OpenSSL 3.5.5 27 Jan 2026`; both Alpine images resolve `OpenSSL 3.5.7 9 Jun 2026`.
  That is inherent to the flavour -- the whole point of `openssl-dynamic` is that it takes the
  distro's libssl -- but it means the +12% is "glibc image with 3.5.5 against musl image with 3.5.7",
  not "the same library on two libcs". **This confound is not recorded anywhere else and it should be
  stated in any write-up.** `boringssl-static` has no such problem: BoringSSL is compiled in, so its
  no-effect result is clean.
- **The temurin glibc-vs-musl pair also differs in JDK build**: `eclipse-temurin:21-jdk` is 21.0.12,
  `eclipse-temurin:21-jdk-alpine` is 21.0.11. `amazoncorretto:21-alpine` is 21.0.12, which is why the
  amazoncorretto replication matters -- it is a musl image on the same JDK build as the glibc
  control.
- Handshake cost only. No bulk-crypto or throughput axis was measured.
- x86_64 only. One cipher per protocol version. `bufferType=DIRECT` only.
- One host, one run per cell (three forks within it).

## Related

- [A3](A3-openssl-dynamic-alpine-workaround.md) -- where the openssl-dynamic flavour comes from
- [A5](A5-key-exchange-group-sweep.md) -- what the TLS 1.3 rows are actually spending time on
- [A6](A6-tls12-vs-tls13-group-controlled.md) -- decomposing the TLS 1.3 gap
- [A10](A10-patched-tcnative-matrix-gate.md) -- the patched boringssl build these numbers come from
