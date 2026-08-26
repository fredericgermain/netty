# D4. Q3 instrumented run: where does the CPU go

**Confidence:** SOLID
**Date:** 2026-08-25 late evening or 2026-08-26 early (after commit `6aa7c67b2a`, 2026-08-25 22:22,
"Instrument the load test with CPU, GC and context-switch counters")
**Question:** the plaintext deficit costs io_uring about 25% of throughput -- where is that CPU
going, and on which side?

## Configuration

Driver `benchmark-report/scripts/thor-q3.sh`.

- 10,000 connections, 10 s steady state, 1 KB payload, closed loop
- 5 rounds, four cells interleaved per round: epoll plaintext, io_uring plaintext, epoll TLS,
  io_uring TLS
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- CPU from `/proc/self/stat` fields 14/15, summed over `/proc/self/task/*`; GC from
  `GarbageCollectorMXBean`
- Both sides instrumented, reported as microseconds per request

## Result

Medians per request, microseconds, plaintext cells:

| | req/s | client utime | client stime | server utime | server stime |
|---|---|---|---|---|---|
| epoll plaintext | 152,227 | 8.40 | 15.34 | 5.90 | 15.49 |
| io_uring plaintext | 114,980 | 13.53 | 20.13 | 6.28 | 12.80 |

**Upgraded from RECALLED to SOLID.** All ten values verified as medians of the five rounds in
`benchmark-report/logs/q3.log`.

The TLS cells from the same run were never tabulated. Their medians:

| | req/s | client utime | client stime | server utime | server stime |
|---|---|---|---|---|---|
| epoll TLS | 85,043 | 22.29 | 18.97 | 20.36 | 19.13 |
| io_uring TLS | 111,042 | 18.51 | 15.63 | 18.92 | 15.20 |

The io_uring TLS column also carries the five-round sequence 70,442 / 82,764 / 111,042 / 115,721 /
115,189 that was later withdrawn as a warm-up trend -- see
[D19](D19-tls-warmup-and-ordering.md). `q3.log` is the primary source for that withdrawn claim.

## Reading

Establishes that io_uring's client burns markedly more CPU per request: +61% user time (13.53 against
8.40) and +31% system time (20.13 against 15.34). That part survives.

**Two conclusions drawn from this run were later withdrawn** -- see
[D9](D9-cross-transport-2x2.md):

1. that the deficit was client-side
2. that io_uring saved 17% of server kernel time (12.80 against 15.49)

Both errors have the same shape: reading a per-request CPU figure from a single *paired* run as if it
were a property of one side. In a closed-loop pipeline both sides run at the same request rate, so a
per-request figure on either side is a property of the pair.

Does **not** locate the CPU within either process. That needed profiling --
[D6](D6-async-profiler-ctimer-plaintext-client.md) and
[D12](D12-kernel-profiling-at-1kb.md).

## Raw data

- `benchmark-report/logs/q3.log` -- five rounds, four cells, all columns
- `benchmark-report/scripts/thor-q3.sh`

## Caveats

- Old SMT-sibling pinning.
- **The withdrawn 12.80 us server-kernel figure is the median of a wide spread.** The five io_uring
  plaintext `srvS/req` values in `q3.log` are 12.78, 14.02, 21.34, 12.53, 12.80 -- a range of 12.53
  to 21.34. `FINDINGS.md` describes this spread as "12.6 to 22.4"; the log says 12.53 to 21.34.
  The point stands either way: a 17% saving read off one number inside that spread was never real.
- 1 KB payload only, loopback, queue depth 1, kernel 6.8, 4 physical cores shared.
- Closed loop.
- The TLS rows above are medians of cells whose round-to-round spread exceeds 40%. They are recorded
  for provenance, not as results.
- CPU is measured for the whole JVM, not per thread or per call site.

## Related

- [D3](D3-interleaved-transport-comparison.md) -- the same cells without instrumentation
- [D5](D5-gc-hypothesis.md) -- the GC column of this same run
- [D9](D9-cross-transport-2x2.md) -- the run that withdrew two claims from here
- [D19](D19-tls-warmup-and-ordering.md) -- the withdrawn TLS warm-up trend, sourced here
