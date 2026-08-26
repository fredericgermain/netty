# A9. Never executed

**Confidence:** UNCERTAIN
**Date:** workflow committed 2026-08-20 (file mtime 20 Aug 13:18); never run as of 2026-08-26
**Question:** what in Part A was built but never actually measured?

## Configuration

Not applicable. This entry records absence.

## Result

- `.github/workflows/ci-tls-matrix.yml` is committed (5,392 bytes) and **has never run**. It needs a
  fork with Actions enabled, and this checkout has only `origin` pointing at upstream `netty/netty`,
  so there is no fork remote to push to.
- The payload-size and certificate-type axes (phase 6 of the original plan) were **never started**.
  No script, no harness support, no partial run.

## Reading

Establishes only that these exist as intentions. Nothing about them should appear in a write-up as a
result.

The workflow being committed but unexecuted is worth a sentence of its own: it is exactly the shape
of CI that would report green while measuring nothing, which is the trap
[A8](A8-negative-controls.md) was written to close. Whether the controls fire correctly *inside
Actions* is untested.

## Raw data

- `.github/workflows/ci-tls-matrix.yml` -- committed, unexecuted
- `.github/scripts/tls-matrix/` -- `matrix.sh`, `run.sh`, `aggregate.py`, `tag_results.py`,
  `README.md`. These have all run locally via `benchmark-report/scripts/thor-x86.sh`; only the
  Actions wrapper has not.
- **No run log exists**, by definition.

## Caveats

- The whole of Part A ran on one host, driven by hand. None of it has been reproduced by CI, so
  nothing is protected against regression.
- The missing payload-size axis is not cosmetic. Every Part A number is a *handshake* cost; nothing
  in Part A measures bulk throughput or record-layer cost, and the two are frequently conflated in
  TLS benchmark write-ups.
- The missing certificate-type axis means every Part A number is RSA. ECDSA handshake costs are
  materially different and are not measured here at all.

## Related

- [A8](A8-negative-controls.md) -- the controls the workflow would carry
- [A1](A1-microbench-jar-on-alpine.md) -- the microbench fixes the workflow would guard
