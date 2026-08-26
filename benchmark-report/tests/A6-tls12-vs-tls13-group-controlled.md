# A6. TLS 1.2 vs TLS 1.3, group controlled and uncontrolled

**Confidence:** SOLID
**Date:** own-defaults row 2026-08-25 13:15:23Z (JMH records); pinned-group rows 2026-08-25 around
14:57 BST (`groups.log`)
**Question:** how much of the "TLS 1.3 is slower than TLS 1.2" gap is the protocol version and how
much is the key exchange group each version happens to default to?

## Configuration

Two runs, deliberately different, which is why the rows come from different artifacts.

**Own-defaults row** -- from the insight matrix, `benchmark-report/scripts/thor-insight.sh`:
`boringssl-static` 2.0.82.Final-SNAPSHOT, `eclipse-temurin:21-jdk` (glibc), `-f 3 -wi 5 -i 10`,
`sslProvider=OPENSSL`, `bufferType=DIRECT`, ciphers
`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` and `TLS_AES_128_GCM_SHA256`. No group pinned, so each
version takes its own default.

**Pinned-group rows** -- from `benchmark-report/scripts/thor-groups.sh`: same
`boringssl-static` 2.0.82.Final-SNAPSHOT but `eclipse-temurin:21-jdk-alpine` (musl),
`-f 3 -wi 5 -i 10 -r 2s -w 2s`, `-Dnetty.bench.tls.groups` set explicitly on both versions.

Neither run pins CPUs.

## Result

| comparison | TLS 1.2 | TLS 1.3 | gap |
|---|---|---|---|
| own defaults | 804.2 +/- 16.9 | 1346.3 +/- 11.1 | +67% |
| X25519 pinned both | 769.8 +/- 11.8 | 1004.0 +/- 12.2 | +30% |

A third row exists in `groups.log` and was never recorded in the catalogue:

| comparison | TLS 1.2 | TLS 1.3 | gap |
|---|---|---|---|
| P-256 pinned both | 778.4 +/- 13.4 | 985.4 +/- 6.3 | +27% |

Verbatim from `benchmark-report/logs/groups.log`:

```
TLS1.2  group=X25519                           769.753 ± 11.773 us/op
TLS1.3  group=X25519                           1004.029 ± 12.188 us/op
TLS1.2  group=P-256                            778.397 ± 13.402 us/op
TLS1.3  group=P-256                            985.442 ± 6.287 us/op
```

And from `benchmark-report/jmh/insight-bssl/eclipse-temurin-21-jdk__boringssl__insight.jsonl`:
804.1516943792827 +/- 16.891525543696304 (TLS 1.2) and 1346.3277020783978 +/- 11.070154480576507
(TLS 1.3), both `us/op`.

**Upgraded from RECALLED to SOLID.** The own-defaults row is verified against the committed JSONL;
the pinned rows are verified against `groups.log`.

## Reading

Roughly half of the apparent 67% TLS 1.3 penalty is the post-quantum group and roughly half is a real
protocol-version difference. The newly-recovered P-256 row agrees: +27% with the group controlled,
close to X25519's +30%. Two independent group choices give the same controlled gap, which is a
stronger result than one.

Anyone comparing TLS 1.2 with TLS 1.3 without pinning the group is reporting the first row while
believing they are reporting the second.

Does **not** establish a like-for-like protocol comparison in the strict sense. Even with the group
pinned, the cipher suites differ (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` against
`TLS_AES_128_GCM_SHA256`) because they must -- TLS 1.3 renamed and re-scoped suites. Some of the
remaining 30% could be that rather than the protocol.

**The two rows are not from the same run.** Row 1 is glibc; rows 2 and 3 are musl, with different JMH
warm-up settings. That does not damage the *within-row* gaps, which is what the argument uses, but
the absolute 804.2 and 769.8 should not be subtracted from each other.

## Raw data

- `benchmark-report/logs/groups.log` -- pinned-group rows, section "same group on both protocol
  versions"
- `benchmark-report/jmh/insight-bssl/eclipse-temurin-21-jdk__boringssl__insight.jsonl` -- own-defaults
  row
- `benchmark-report/scripts/thor-groups.sh`, `benchmark-report/scripts/thor-insight.sh`

## Caveats

- Cross-run comparison between row 1 and rows 2-3, on different images and different JMH settings.
  Stated above; do not narrow it.
- Handshake cost only, loopback, microbenchmark, x86_64.
- One tcnative flavour and version.
- The cipher-suite difference between versions is unavoidable and uncontrolled.

## Related

- [A5](A5-key-exchange-group-sweep.md) -- the group sweep this depends on
- [A4](A4-libc-effect-by-tcnative-flavour.md) -- the source of the own-defaults numbers
- [A7](A7-cloud-endpoint-negotiation.md) -- why the uncontrolled row is the one people meet
