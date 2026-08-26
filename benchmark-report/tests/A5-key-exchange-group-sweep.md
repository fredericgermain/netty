# A5. Key exchange group sweep

**Confidence:** SOLID
**Date:** 2026-08-25, around 14:57 BST (commit `5472c9acba`, "Make the key exchange group explicit");
the groups jar build finished 2026-08-25T12:42:46Z
**Question:** is BoringSSL's default TLS 1.3 key exchange group the post-quantum hybrid, and what does
it cost?

## Configuration

Driver `benchmark-report/scripts/thor-groups.sh`. Everything held fixed, only
`-Dnetty.bench.tls.groups` varied, consumed via `OpenSslContextOption.GROUPS` (an option added on
this branch).

- Jar: `mb-groups.jar`, `microbench` built with `-Pbenchmark-jar,boringssl-snapshot`,
  `-Dtcnative.classifier=linux-x86_64`, so `boringssl-static` 2.0.82.Final-SNAPSHOT
- Image: `eclipse-temurin:21-jdk-alpine`
- JMH: `-f 3 -wi 5 -i 10 -r 2s -w 2s`, mode `avgt`
- Fixed parameters: `-p sslProvider=OPENSSL -p bufferType=DIRECT`,
  `-p cipher=TLS_AES_128_GCM_SHA256` (TLS 1.3)
- No CPU pinning; idle host

## Result

| group | score |
|---|---|
| default | 1383.7 +/- 17.6 |
| X25519MLKEM768 | 1367.3 +/- 12.2 |
| X25519 | 1043.7 +/- 11.7 |
| P-256 | 1000.8 +/- 9.0 |

Verbatim from `benchmark-report/logs/groups.log`:

```
TLS1.3  group=<provider default>               1383.662 ± 17.634 us/op
TLS1.3  group=X25519 (classical)               1043.658 ± 11.675 us/op
TLS1.3  group=X25519MLKEM768 (what S3 uses)    1367.343 ± 12.245 us/op
TLS1.3  group=P-256                            1000.800 ± 9.037 us/op
```

**Upgraded from RECALLED to SOLID.** Verified against `benchmark-report/logs/groups.log`, which
carries every value to three decimals.

## Reading

The provider default and the explicit post-quantum hybrid are the same number to within a fifth of
their combined error, which is how you know the default *is* the hybrid. Pinning classical X25519
instead is about 25% cheaper; P-256 is cheaper still.

Does **not** establish that the default is X25519MLKEM768 by *identity*. It establishes that the
default costs what X25519MLKEM768 costs. A packet capture or an `SSL_get_negotiated_group()` call
would settle it directly and neither was done. The inference is strong but it is an inference.

Does **not** say anything about handshake *security*, only cost, and nothing about the bandwidth cost
of the larger key share -- only CPU time per handshake.

## Raw data

- `benchmark-report/logs/groups.log` -- the full sweep, both sections
- `benchmark-report/logs/jar-groups.log` -- the jar build, `BUILD SUCCESS`, finished
  2026-08-25T12:42:46Z
- `benchmark-report/scripts/thor-groups.sh`
- No per-run JMH JSON was kept for this sweep; `thor-groups.sh` greps the console table rather than
  calling `run.sh`, so there is no tagged JSONL under `benchmark-report/jmh/` for it.

## Caveats

- One image (`eclipse-temurin:21-jdk-alpine`, musl), one provider (`OPENSSL` /
  `boringssl-static` 2.0.82-SNAPSHOT), one cipher.
- Handshake cost only, on loopback, in a microbenchmark. No network round trips, so the extra bytes
  of an MLKEM key share cost nothing here that they would cost on a real link.
- The group set is whatever this BoringSSL build supports. A different tcnative or a different
  BoringSSL revision may pick a different default.
- x86_64 only.
- Scores are not directly comparable with [A4](A4-libc-effect-by-tcnative-flavour.md): this run adds
  `-r 2s -w 2s` and uses a differently-built jar.

## Related

- [A6](A6-tls12-vs-tls13-group-controlled.md) -- the same run's second half, decomposing the
  TLS 1.2 / TLS 1.3 gap
- [A7](A7-cloud-endpoint-negotiation.md) -- the same group on a real endpoint
- [A4](A4-libc-effect-by-tcnative-flavour.md) -- the TLS 1.3 rows this explains
