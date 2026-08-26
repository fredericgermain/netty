# D3. Interleaved transport comparison, 5 rounds

**Confidence:** SOLID
**Date:** 2026-08-25 late evening or 2026-08-26 early (after commit `6aa7c67b2a`, 2026-08-25 22:22)
**Question:** with the four cells interleaved round by round so every cell sees the same machine
drift, how do the transports compare on plaintext and on TLS?

## Configuration

Driver `benchmark-report/scripts/thor-inversion.sh`.

- 10,000 connections, 10 s steady state, 1 KB payload, closed loop
- 5 rounds, four cells interleaved within each round: epoll plaintext, io_uring plaintext, epoll TLS,
  io_uring TLS
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- TLS cells use `--tls=openssl` (tcnative/BoringSSL)
- `load1m` sampled once per round

## Result

| cell | round spread | verdict |
|---|---|---|
| epoll plaintext | 161,845 - 166,798 | epoll ~39% faster, robust |
| io_uring plaintext | 118,002 - 121,729 | |
| epoll TLS | 67,460 - 95,527 (42%) | not established at the time |
| io_uring TLS | 83,451 - 117,973 (41%) | |

Per-round, verbatim from `benchmark-report/logs/inversion2.log`:

```
round load1m  epoll-plain  iouring-plain  epoll-tls  iouring-tls
1      7.34     166798       118130         91586      83451
2      12.03    166372       118002         95527      109748
3      12.91    164919       118693         70730      106199
4      12.62    161845       121729         94202      104336
5      12.87    163732       118435         67460      117973
```

Medians: epoll plaintext 164,919, io_uring plaintext 118,435, ratio **1.39x**. epoll TLS 91,586,
io_uring TLS 106,199.

**Upgraded from RECALLED to SOLID.** Every bound in the catalogue table matches
`benchmark-report/logs/inversion2.log` exactly, and the ~39% figure recomputes from the medians.

## Reading

Establishes the plaintext result properly. Four non-overlapping round spreads, epoll ahead in all
five rounds, spread of only 3% within each plaintext cell. This is the result the rest of Part D
tries to explain.

Establishes that the TLS cells at 1 KB were **not** measurable at five rounds. 42% and 41% spreads,
and epoll's slowest TLS round is lower than io_uring's slowest. Nothing about TLS could be concluded
here, which is what drove [D19](D19-tls-warmup-and-ordering.md).

Does **not** attribute the plaintext deficit to a side. That took
[D9](D9-cross-transport-2x2.md), which withdrew two claims made from this shape of data.

Does **not** generalise beyond 1 KB. [D10](D10-payload-sweep-and-zero-copy.md) shows the ratio
roughly triples by 256 KB.

## Raw data

- `benchmark-report/logs/inversion2.log` -- the five rounds above
- `benchmark-report/logs/inversion.log` -- **the failed first attempt.** Every cell reads
  `./thor-inversion.sh: line 25: t: unbound variable`, five rounds of nothing. The committed
  `thor-inversion.sh` is the fixed version; the broken one is not preserved. Worth knowing that
  `inversion.log` contains no data at all, since `TESTS.md` listed it as an "early interleaved
  transport run".
- `benchmark-report/scripts/thor-inversion.sh`

## Caveats

- Old SMT-sibling pinning throughout.
- **The machine was not in a steady state.** `load1m` is 7.34 in round 1 and 12.03 to 12.91 in rounds
  2-5. Interleaving protects the *comparison* between cells within a round; it does not make the
  absolute numbers comparable across rounds.
- 1 KB payload only, loopback, queue depth 1, kernel 6.8, 4 physical cores shared.
- Closed loop, so the harness's p50 is queue depth.
- The TLS cells are reported here for completeness. They do not support a conclusion.

## Related

- [D1](D1-first-10k-connection-runs.md) -- the single-run predecessor
- [D4](D4-q3-cpu-accounting.md) -- the instrumented follow-up on the same cells
- [D9](D9-cross-transport-2x2.md) -- attributing the deficit to a side
- [D19](D19-tls-warmup-and-ordering.md) -- the TLS question, done properly
