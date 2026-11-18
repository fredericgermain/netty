# A7. What a real cloud endpoint negotiates

**Confidence:** SOLID
**Date:** re-run 2026-11-18T21:30Z, captured. The original probe was roughly 2026-08-25 and was never
recorded.
**Question:** is the post-quantum hybrid key exchange a lab default nobody meets, or does a
mainstream cloud endpoint actually negotiate it today?

## Configuration

`benchmark-report/scripts/endpoint-probe.sh`, from thor (kernel 7.0.14), client OpenSSL 3.5.5 built
2026-08-26. Two endpoints, `s3.eu-west-1.amazonaws.com` and `s3.us-east-1.amazonaws.com`, each
probed under four client offers, because a server selects from the offer and the original probe
recorded only the selection:

| offer | `-groups` |
|---|---|
| default | the client's own list, captured from its ClientHello: `X25519MLKEM768, x25519, P-256, x448, P-384, P-521, ffdhe2048, ffdhe3072` |
| pq-first | `X25519MLKEM768:X25519:P-256` |
| no-pq | `X25519:P-256` |
| p256-only | `P-256` |

Then ten repeats of the default arm against `s3.eu-west-1.amazonaws.com`, tallied with the server IP,
to test whether one probe is enough. Not a timed benchmark.

## Result

**The recalled result is confirmed, and one part of it turns out not to be a property of the
endpoint.**

| host | offer | version | ciphersuite | group | sigalg |
|---|---|---|---|---|---|
| s3.eu-west-1 | default | TLSv1.3 | TLS_AES_128_GCM_SHA256 | **X25519MLKEM768** | rsa_pss_rsae_sha256 |
| s3.eu-west-1 | pq-first | TLSv1.3 | TLS_AES_128_GCM_SHA256 | **X25519MLKEM768** | rsa_pss_rsae_sha256 |
| s3.eu-west-1 | no-pq | TLSv1.3 | TLS_AES_128_GCM_SHA256 | X25519 | rsa_pss_rsae_sha256 |
| s3.eu-west-1 | p256-only | TLSv1.3 | TLS_AES_128_GCM_SHA256 | prime256v1 | rsa_pss_rsae_sha256 |
| s3.us-east-1 | default | TLSv1.3 | TLS_AES_128_GCM_SHA256 | **X25519MLKEM768** | rsa_pss_rsae_sha256 |
| s3.us-east-1 | pq-first | TLSv1.3 | TLS_AES_128_GCM_SHA256 | **X25519MLKEM768** | rsa_pss_rsae_sha256 |
| s3.us-east-1 | no-pq | TLSv1.3 | TLS_AES_128_GCM_SHA256 | X25519 | rsa_pss_rsae_sha256 |
| s3.us-east-1 | p256-only | TLSv1.3 | TLS_AES_128_GCM_SHA256 | prime256v1 | rsa_pss_rsae_sha256 |

Three things the original single probe could not say:

1. **The group is the server's choice, not an artefact of the offer order.** `pq-first` and `default`
   agree, and the hybrid is first in the client's own list either way -- but the server also takes it
   when it is offered alongside two classical groups it could have preferred. The two no-PQ arms show
   the fallback is ordinary ECDHE, which answers the original doc's guess ("a client offering only
   X25519 would presumably have got X25519") with a measurement instead.
2. **It is not one region.** us-east-1 behaves identically to eu-west-1 on all four arms.
3. **The ciphersuite is not stable, and the recalled result quoted it as if it were.** Ten repeats of
   the default arm: group `X25519MLKEM768` 10/10; ciphersuite `TLS_AES_128_GCM_SHA256` 8/10 and
   `TLS_CHACHA20_POLY1305_SHA256` 2/10. Two of the server IPs returned *both* suites on different
   connections, so this is not just different edge machines behind one name. An earlier run of ten the
   same evening split 5/5. The group is the finding; the ciphersuite in the original claim was one
   connection's luck.

## Reading

This is the detail that turns [A5](A5-key-exchange-group-sweep.md) from a curiosity into a finding. A
current, mainstream cloud endpoint is doing post-quantum hybrid key exchange right now, in two
regions, under a client offer that gives it classical alternatives. A modern client benchmarking
"TLS 1.3" against it is measuring post-quantum crypto whether or not it meant to -- which is exactly
the confound A5 had to control for, and the reason the uncontrolled TLS 1.2-vs-1.3 gap in
[A6](A6-tls12-vs-tls13-group-controlled.md) was half group and half protocol.

Does **not** establish that AWS *prefers* X25519MLKEM768 over every alternative; it establishes that
it takes it when offered, including when classical groups are offered with it, and that it falls back
cleanly when it is not.

Does **not** generalise beyond S3. Two regions of one service were probed.

## Raw data

- `benchmark-report/logs/a7-endpoint-negotiation.log` -- the full capture: client version and build
  date, the ClientHello `supported_groups` the client actually sent, all eight arms, and the ten-repeat
  tally with server IPs.
- `benchmark-report/scripts/endpoint-probe.sh` -- re-run it. `endpoint-probe.sh <host>...` takes other
  endpoints; `REPEAT=n` changes the tally size.

## Caveats

- **This is exactly the kind of fact that changes.** Server-side group preferences move with fleet
  rollouts. The probe is now one command, so re-run it immediately before publishing rather than
  citing this capture.
- The client is OpenSSL 3.5.5. A client without `X25519MLKEM768` compiled in cannot see this result
  at all, and that is the point of recording the offer.
- Two regions of one AWS service. Nothing here says what other services or other providers do.
- The ciphersuite column is per-connection, not a property of the endpoint; see result 3.

## Related

- [A5](A5-key-exchange-group-sweep.md) -- what that group costs
- [A6](A6-tls12-vs-tls13-group-controlled.md) -- why it distorts version comparisons
