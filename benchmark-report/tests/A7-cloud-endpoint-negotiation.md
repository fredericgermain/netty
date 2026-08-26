# A7. What a real cloud endpoint negotiates

**Confidence:** SOLID, RECALLED
**Date:** roughly 2026-08-25, not precisely recorded
**Question:** is the post-quantum hybrid key exchange a lab default nobody meets, or does a
mainstream cloud endpoint actually negotiate it today?

## Configuration

A single `openssl s_client` probe of `s3.eu-west-1.amazonaws.com` from a workstation. The exact
command line, the client's OpenSSL version and the offered group list were not recorded, which
matters: what a server *selects* depends on what the client *offers*.

## Result

`s3.eu-west-1.amazonaws.com`: TLSv1.3, TLS_AES_128_GCM_SHA256, **X25519MLKEM768**,
rsa_pss_rsae_sha256.

## Reading

This is the detail that turns [A5](A5-key-exchange-group-sweep.md) from a curiosity into a finding.
A current, mainstream cloud endpoint is doing post-quantum hybrid key exchange right now, so a modern
client benchmarking "TLS 1.3" against it is measuring post-quantum crypto whether or not it meant to.

Does **not** establish that AWS *prefers* X25519MLKEM768, only that it selected it against whatever
this client offered. A client offering only X25519 would presumably have got X25519.

Does **not** generalise to other endpoints, other regions, or other AWS services. One host was
probed.

## Raw data

**None committed.** There is no log, no transcript and no capture of this probe anywhere in
`benchmark-report/`. It exists only as a recalled result.

This is the single least-evidenced claim in Part A and it is load-bearing for the article. Re-run it,
capture the full `openssl s_client -connect s3.eu-west-1.amazonaws.com:443` output including the
client version and the negotiated group line, and commit it.

## Caveats

- Undated to better than a day.
- Client-side configuration unrecorded, so the result is not reproducible as stated.
- **This is exactly the kind of fact that changes.** Server-side group preferences move with fleet
  rollouts. Re-verify immediately before publishing; do not publish the recalled version.
- One endpoint, one region, one probe.

## Related

- [A5](A5-key-exchange-group-sweep.md) -- what that group costs
- [A6](A6-tls12-vs-tls13-group-controlled.md) -- why it distorts version comparisons
