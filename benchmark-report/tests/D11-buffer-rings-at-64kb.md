# D11. Buffer rings at 64 KB

**Confidence:** SOLID
**Date:** 2026-08-26, between 07:09 and 07:31 BST (between commits `dd16437461` and `1669454637`)
**Question:** [D7](D7-buffer-rings-at-1kb.md) asked the buffer-ring question at 1 KB and found
nothing -- does it help at 64 KB, where the deficit is three times larger?

## Configuration

Driver `benchmark-report/scripts/thor-bigbuf.sh`. Jar `loadtest-zc.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- 64 KB payload, **2,000 connections**, 10 s, plaintext, closed loop
- **3 rounds**, four cells interleaved per round
- `--threads=4`, `--backlog=8192`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- Cells, as `--buffer-ring=<entries> --buffer-ring-size=<bytes>`: epoll `0 2048`, io_uring `0 2048`,
  io_uring `512 65536`, io_uring `2048 16384`

## Result

| cell | rounds | median |
|---|---|---|
| epoll | 40,493 - 42,234 | 40,999 |
| io_uring, no ring | 18,682 - 18,754 | 18,702 |
| io_uring + 512 x 64 KB | 19,421 - 19,787 | 19,680 |
| io_uring + 2048 x 16 KB | 19,019 - 19,427 | 19,118 |

A real, non-overlapping **+5%** -- 18,702 to 19,680 -- recovering about 4% of a 120% gap.

## Reading

Establishes that the effect is real in the statistical sense: the no-ring and 512x64KB spreads do not
overlap across three rounds, and the no-ring cell is remarkably tight (18,682 to 18,754, 0.4%).

Establishes that it does not matter. +5% against a gap where epoll is 2.2x faster is not a
remediation.

**This result is now suspect, and the doubt is the more useful output.** Enabling a provided buffer
ring should delete the POLL_ADD round trip entirely -- see
[D17](D17-mechanism-discriminator.md), where `isPollInFirst()` returning true is shown to cost a
POLL_ADD *then* a RECV on every read. Deleting one of two submissions and two completions per read
should be worth far more than 5%. A +5% is more consistent with **the ring never engaging** than with
it engaging and not helping. The cell needs an `isUsable()` assertion that aborts the run rather than
silently falling back.

Does **not** distinguish those two possibilities. Nothing in the harness or the log confirms the ring
was accepted by the kernel and used.

Does **not** cover the 2048 x 16 KB cell's underperformance. It is below the 512 x 64 KB cell, which
is consistent with buffers smaller than the payload forcing more reads, but three rounds cannot
support that as a finding.

## Raw data

- `benchmark-report/scripts/thor-bigbuf.sh` -- the driver, confirming payload, connections, rounds and
  all four cell configurations
- **No run log is committed.** There is no `bigbuf.log` in `benchmark-report/logs/`. The spreads and
  medians above are carried forward from the catalogue and **could not be verified against raw
  output**.
- The epoll and io_uring baselines are corroborated by other 64 KB runs under the same old pinning:
  `pc64.log` gives epoll 41,504 and io_uring 18,139; `mech64.log` (corrected pinning) gives 40,630 and
  17,257.

## Caveats

- **Raw data not committed.**
- **Only 3 rounds**, the fewest of any interleaved sweep in Part D.
- **No assertion that the ring engaged.** This is the caveat that undermines the result.
- Old SMT-sibling pinning.
- Ring applied to both client and server.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared, 2,000 connections.
- One payload size.
- Related netty bug, verified in source: `IoUringBufferRingConfig.builder()` cannot be used without
  calling `batchSize()`.

## Related

- [D7](D7-buffer-rings-at-1kb.md) -- the same question at 1 KB
- [D17](D17-mechanism-discriminator.md) -- why a working ring should be worth much more than 5%
- [D14](D14-pooled-memory-measurement.md) -- a buffer ring's effect on memory, measured separately
- [D21](D21-stacked-remediation.md) -- the remediation that does work
