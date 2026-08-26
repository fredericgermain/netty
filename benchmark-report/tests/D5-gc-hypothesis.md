# D5. GC hypothesis

**Confidence:** SOLID
**Date:** same run as [D4](D4-q3-cpu-accounting.md), 2026-08-25 late evening or 2026-08-26 early
**Question:** is the round-to-round swing in the TLS cells, and the deficit generally, explained by
garbage collection pauses?

## Configuration

The GC column of the [D4](D4-q3-cpu-accounting.md) run. Driver
`benchmark-report/scripts/thor-q3.sh`, 10,000 connections, 10 s, 1 KB, closed loop, 5 interleaved
rounds, old SMT-sibling pinning, image `eclipse-temurin:21-jdk-alpine`. `gcMs` is total pause time
from `GarbageCollectorMXBean` over the steady-state window, client side.

## Result

**Falsified.** `gcMs` across the TLS rounds runs 71 to 97 while throughput swings 70k to 116k.

Per-round, from `benchmark-report/logs/q3.log`:

| round | epoll TLS req/s | epoll gcMs | io_uring TLS req/s | io_uring gcMs |
|---|---|---|---|---|
| 1 | 92,021 | 85 | 70,442 | 87 |
| 2 | 85,043 | 95 | 82,764 | 90 |
| 3 | 82,713 | 96 | 111,042 | 73 |
| 4 | 95,360 | 77 | 115,721 | 97 |
| 5 | 77,030 | 71 | 115,189 | 87 |

epoll's slowest TLS round (77,030) had its lowest GC (71 ms); its fastest (95,360) had 77 ms. No
correlation, and the correlation runs the wrong way if anything.

Also noted: the asymmetry that motivated the hypothesis (plaintext 3% spread vs TLS 42%) did not
reproduce. In this run plaintext spanned 22% (137,804 to 168,761 on epoll) and TLS 23% (77,030 to
95,360 on epoll).

**Upgraded from RECALLED to SOLID.** Verified against `benchmark-report/logs/q3.log`.

**Correction:** the catalogue said `gcMs` ran "between 71 and 99 across TLS rounds". Across the TLS
rounds the range is **71 to 97**. The value 99 appears in the log on io_uring *plaintext* round 2, not
on any TLS round. 71 to 99 is the range across all rounds of both workloads. The conclusion is
unaffected.

## Reading

Establishes that GC is not the mechanism, and does it the cheap way: the hypothesis predicted a
correlation, the data has none, and the one clean anti-correlation (slowest round, lowest GC) is
enough on its own.

Also establishes that the 3%-vs-42% asymmetry which motivated the hypothesis was itself a property of
one run rather than of the workload. That is the more transferable lesson: the *thing to be
explained* had not been established before an explanation was sought for it.

Does **not** rule out allocation cost that never becomes a pause. `gcMs` measures stop-the-world
pause time only. The direct-memory churn found later in
[D13](D13-profiling-at-256kb.md) and [D14](D14-pooled-memory-measurement.md) is real allocation
pressure that produces no GC pause at all, because it is off-heap.

## Raw data

- `benchmark-report/logs/q3.log` -- `gcMs` column, all five rounds, all four cells
- `benchmark-report/scripts/thor-q3.sh`

## Caveats

- Client-side GC only. The server's GC counters were not reported by this script version.
- Total pause time, not pause distribution. A single long pause and many short ones look the same.
- Default JVM GC settings; no collector was selected explicitly, so this is whatever
  `eclipse-temurin:21-jdk-alpine` defaults to for the container's memory limits.
- Old SMT-sibling pinning, 1 KB payload, loopback, queue depth 1, kernel 6.8, 4 physical cores
  shared.
- Five rounds.

## Related

- [D4](D4-q3-cpu-accounting.md) -- the same run's CPU columns
- [D13](D13-profiling-at-256kb.md) -- off-heap allocation, which GC pause time cannot see
- [D14](D14-pooled-memory-measurement.md) -- the direct-memory churn measured directly
