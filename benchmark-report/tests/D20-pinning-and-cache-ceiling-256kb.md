# D20. Pinning and cache-ceiling sweep, 256 KB

**Confidence:** SOLID
**Date:** 2026-08-26, around 07:46 BST (same sweep as
[D16](D16-pinning-and-cache-ceiling-64kb.md), commit `1cf2d79e73`)
**Question:** [D16](D16-pinning-and-cache-ceiling-64kb.md) asked about the pinning artifact and the
cache ceiling at 64 KB. What happens at 256 KB, where io_uring is at its worst?

**This test was not in the catalogue.** `TESTS.md` listed `pc256.log` twice as existing on thor and
**never read** -- once in the raw-data table and once as an open item. It is committed, it is
complete, and it answers the question differently from the 64 KB sweep.

## Configuration

Driver `loadtest/scripts/thor-pincache.sh`, invoked as `thor-pincache.sh 262144 500 5`. Jar
`loadtest-pin.jar`, image `eclipse-temurin:21-jdk-alpine`.

- **256 KB payload, 500 connections, 10 s**, plaintext, closed loop
- **5 rounds, six cells interleaved per round**
- `--threads=4`, `--backlog=8192`, `--tls=none`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`, `memlock=-1`

Both pinnings measured in the same sweep:

| suffix | server cpuset | client cpuset |
|---|---|---|
| `-old` | `0-3` | `4-7` (SMT siblings) |
| `-new` | `0,1,4,5` | `2,3,6,7` (whole physical cores) |

`-c` adds `-Dio.netty.allocator.maxCachedBufferCapacity=262144` (256 KB) on **both** sides.

## Result

Medians of five rounds:

| cell | median | io_uring as % of epoll | server pool range |
|---|---|---|---|
| epoll old | 8,604 | | 32-32 MB |
| io_uring old | 3,878 | 45.1% | 32-156 MB |
| epoll new | 8,609 | | 32-32 MB |
| io_uring new | 3,957 | 46.0% | 32-156 MB |
| epoll new + cache | **6,087** | | 64-64 MB |
| io_uring new + cache | 3,799 | 62.4% | 176-212 MB |

Per-round, verbatim from `benchmark-report/logs/pc256.log`:

```
port=19990 payload=262144 connections=500 rounds=5
round  ep-old     ur-old     ep-new     ur-new     ep-new-c   ur-new-c
1      8616       3830       8609       4057       6080       3799
2      8620       3878       9152       3920       6133       3772
3      8501       3770       8553       3938       6108       3762
4      8604       3921       9215       3957       6087       3807
5      8570       3916       8508       3975       6075       3831
```

## Reading

Two results here, and both differ from the 64 KB sweep.

**The pinning artifact vanishes at 256 KB.** epoll goes 8,604 to 8,609 and io_uring 3,878 to 3,957
when the pinning is corrected -- 0.06% and 2.0%. At 64 KB the same correction cost epoll 16% and
moved the ratio by seven points. At 500 connections and 256 KB the workload is memory-bandwidth bound
rather than scheduler bound, so which logical CPUs the two sides sit on stops mattering. This is
useful for [D10](D10-payload-sweep-and-zero-copy.md), whose 256 KB row was measured under the old
pinning and never re-run: **that row needs no pinning correction.** Its figures of 9,259 and 3,767
sit within 7% and 3% of the medians here.

**The cache ceiling is actively harmful at 256 KB, and mostly to epoll.** Raising
`maxCachedBufferCapacity` to 256 KB costs epoll **29%** (8,609 to 6,087) and costs io_uring 4.0%
(3,957 to 3,799). At 64 KB the same flag *helped* both (epoll +25%, io_uring +15%).

The sign flip is the interesting part and it is legible in the pool column. At 64 KB a 256 KB ceiling
sits comfortably above the buffer size, so buffers land in the thread-local cache and the arena is
left alone. At 256 KB payload the receive buffers are at or above the ceiling, and the cache now
holds 256 KB objects: epoll's flat footprint doubles from 32 MB to 64 MB and its throughput drops by
a third, while io_uring's floor rises from 32 MB to 176 MB. The flag has turned a bounded cache into
a large one and the cost is cache pressure, not allocation.

The ratio "improving" from 46.0% to 62.4% in that last row is therefore **not a remediation**. epoll
got worse. Absolute io_uring throughput went *down*. Any write-up quoting 62.4% without the absolute
numbers would be reporting a regression as a win.

Establishes, with committed evidence, the memory-churn signature at 256 KB: epoll's server pool is
flat at 32 MB in every one of its fifteen cell-runs; io_uring's ranges over 4x in every one of its
fifteen.

Does **not** test a ceiling matched to the payload. A 512 KB or 1 MB ceiling at 256 KB payload is the
configuration that would separate "the ceiling is too low" from "a large cache is bad here".
[D21](D21-stacked-remediation.md) runs 1 MB at 256 KB and gets a different answer again.

## Raw data

- `benchmark-report/logs/pc256.log` -- five rounds, six cells, full per-round detail with server pool
  ranges and client CPU counters. **Previously flagged as never read.**
- `loadtest/scripts/thor-pincache.sh` -- the driver

Client CPU per request from the detail block, showing the same story in CPU terms (round 4 values):
epoll new 200.12 us user + 193.94 us system; io_uring new 412.49 + 333.43; epoll new + cache 376.73 +
269.65. The cache flag roughly doubles epoll's user time per request.

## Caveats

- 256 KB and 500 connections only. Payload and connection count are confounded with the 64 KB sweep,
  which used 2,000 connections.
- The cache flag is applied to both client and server, so the epoll regression cannot be attributed
  to one side. The client CPU figures above suggest the client is at least partly responsible.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared. Even corrected pinning gives two
  physical cores per side.
- Server pool is netty's `usedDirectMemory` accounting, not RSS.
- One cache-ceiling value (256 KB). No sweep.
- The `ep-new` cell spans 8,508 to 9,215 (8.3%), wider than the other five, which are all under 4%.
- Five rounds.

## Related

- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the same sweep at 64 KB, opposite answer on the
  cache ceiling
- [D10](D10-payload-sweep-and-zero-copy.md) -- the single-run 256 KB row this corroborates
- [D13](D13-profiling-at-256kb.md) -- the profile of this workload
- [D14](D14-pooled-memory-measurement.md) -- the pool churn, measured directly
- [D21](D21-stacked-remediation.md) -- a 1 MB ceiling combined with a 512 KB receive buffer
