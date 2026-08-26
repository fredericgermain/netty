# D9. Cross-transport 2x2

**Confidence:** SOLID
**Date:** 2026-08-26, around 06:51 BST (commit `bfba3283e6`, "Cross the transports: the deficit is
symmetric, withdraw two claims")
**Question:** the client and server are independent processes -- if only one side uses io_uring, how
much of the deficit appears?

## Configuration

Driver `benchmark-report/scripts/thor-cross.sh`.

- 10,000 connections, 10 s, 1 KB payload, plaintext, closed loop
- 5 rounds, four server/client combinations interleaved per round
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`, jar `loadtest-br.jar`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`

## Result

| server | client | round spread | median | server stime/req |
|---|---|---|---|---|
| epoll | epoll | 124,125 - 166,896 | 139,356 | 15.6 us |
| io_uring | epoll | 106,844 - 125,922 | 115,252 | 21.5 us |
| epoll | io_uring | 103,556 - 128,112 | 112,656 | 13.8 us |
| io_uring | io_uring | 108,065 - 120,161 | 114,885 | ~20 us |

epoll/epoll leads all five rounds individually.

### Two claims withdrawn from [D4](D4-q3-cpu-accounting.md)

**WITHDRAWN: "the plaintext deficit is client-side."** io_uring on the server alone costs about as
much as on the client alone (115,252 against 112,656), and the two do not add: both together give
114,885, no worse than either alone.

**WITHDRAWN: "io_uring saves 17% of server kernel time."** With the client held at epoll so the
server is measured in isolation, the io_uring server uses **more** kernel time per request: 21.5 us
against 15.6. The 12.80 us figure previously published came from one sample at the low end of a wide
spread.

**Both retractions stand. Do not soften them.** Both errors have the same shape: reading a
per-request CPU figure from a single *paired* run as if it were a property of one side. Only holding
one side fixed can attribute cost to a side.

## Reading

Establishes that the deficit is symmetric and non-additive. That is the signature of a closed-loop
pipeline where the slowest stage sets the rate: whichever side is slower dictates throughput, so a
second slow side costs nothing extra.

Establishes, by consequence, that the two withdrawn claims were artifacts of the experimental design
rather than of the transport.

Does **not** identify the mechanism. It narrows the shape of an acceptable explanation -- it must be
per-operation and present on both sides -- which is what
[D17](D17-mechanism-discriminator.md) eventually satisfies.

Does **not** support a precise magnitude for any single cell. See the caveat below.

## Raw data

- `benchmark-report/scripts/thor-cross.sh` -- the driver, confirming the four combinations
- **No run log is committed.** There is no `cross.log` in `benchmark-report/logs/`. The medians,
  spreads and `stime/req` figures above are carried forward from the catalogue and **could not be
  verified against raw output**.

## Caveats

- **Raw data not committed.**
- **The machine was not steady for the whole run.** epoll/epoll drifted upward across rounds: 131k,
  124k, 139k, 167k, 166k. Interleaving means each round's comparison is fair; it does not make the
  epoll/epoll median a stable number. Its 124k-167k spread is 34%.
- The `~20 us` in the last row is approximate as recorded, and is not a measured figure to three
  digits.
- 1 KB payload only, so this says nothing about the size cliff.
- Old SMT-sibling pinning; loopback; queue depth 1; kernel 6.8; 4 physical cores shared.
- Closed loop, which is precisely why the penalties do not add. In an open-loop test they might.

## Related

- [D4](D4-q3-cpu-accounting.md) -- the run whose claims this withdrew
- [D3](D3-interleaved-transport-comparison.md) -- the same-transport baseline
- [D15](D15-equal-rate-open-loop.md) -- the open-loop control that removes the pipeline effect
- [D17](D17-mechanism-discriminator.md) -- the mechanism this constrains
