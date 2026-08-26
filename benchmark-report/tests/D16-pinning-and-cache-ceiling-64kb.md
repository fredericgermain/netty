# D16. Pinning and cache-ceiling sweep, 64 KB

**Confidence:** SOLID
**Date:** 2026-08-26, around 07:46 BST (commit `1cf2d79e73`, "Measure the SMT pinning artifact and the
cache-ceiling remediation"; script committed at `64304eda9c`, 07:38)
**Question:** how large is the SMT-sibling pinning artifact, and does raising the thread-local cache
ceiling fix the io_uring deficit?

## Configuration

Driver `loadtest/scripts/thor-pincache.sh`, invoked as `thor-pincache.sh 65536 2000 5`. Jar
`loadtest-pin.jar`, image `eclipse-temurin:21-jdk-alpine`.

- **64 KB payload, 2,000 connections, 10 s**, plaintext, closed loop
- **5 rounds, six cells interleaved per round**, so every cell sees the same machine drift
- `--threads=4`, `--backlog=8192`, `--tls=none`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`, `memlock=-1`

**Both pinnings are measured in the same sweep**, which is the point of the test:

| suffix | server cpuset | client cpuset |
|---|---|---|
| `-old` | `0-3` | `4-7` (SMT siblings -- the two sets share four physical cores) |
| `-new` | `0,1,4,5` | `2,3,6,7` (whole physical cores) |

`-c` adds `-Dio.netty.allocator.maxCachedBufferCapacity=262144` (256 KB) as a JVM flag on **both**
server and client. The default is 32 KB, below which the `PooledByteBufAllocator` thread-local cache
refuses to hold a buffer, sending every receive buffer to the arena instead.

On thor, `thread_siblings_list` is `0,4` / `1,5` / `2,6` / `3,7`. Four physical cores, eight logical.

## Result

| cell | median | server pool range |
|---|---|---|
| epoll old | 41,504 | 16-16 MB |
| epoll new | 34,959 | 16-16 MB |
| epoll new + cache | 43,745 | 16-16 MB |
| io_uring old | 18,139 | 16-196 MB |
| io_uring new | 17,794 | 16-212 MB |
| io_uring new + cache | 20,442 | 96-212 MB |

Per-round, verbatim from `benchmark-report/logs/pc64.log`:

```
round  ep-old     ur-old     ep-new     ur-new     ep-new-c   ur-new-c
1      38728      17706      32584      16997      41594      19179
2      40683      17285      39153      16992      42366      21421
3      42512      18139      34959      17794      45175      20366
4      42683      18607      42017      18135      43885      20953
5      41504      18964      34442      18035      43745      20442
```

The SMT artifact was working against io_uring: ratio **43.7% old** (18,139 / 41,504), **50.9%
corrected** (17,794 / 34,959). The cache ceiling helps epoll more than io_uring and is **not** the
fix.

### Corrections against the log

Two figures in the catalogue did not match `pc64.log` and have been corrected here:

| cell | catalogue said | log says (median of 5 rounds) |
|---|---|---|
| epoll old | ~42,008 | **41,504** |
| io_uring old | ~18,373 | **18,139** |

Both were marked approximate with a `~`, and neither is the mean either (means are 41,222 and
18,140). The **ratio is unchanged at 43.7%**, so no conclusion moves. The other four medians match
exactly.

One more correction: the catalogue gave io_uring old's server pool range as `20-196 MB`. That is
round 1's value. Across all five rounds it is **16-196 MB** (per-round: 20-196, 20-196, 24-172,
28-196, 16-192), using the same min-of-mins to max-of-maxes convention applied to the other rows.

## Reading

Establishes the size of the methodology error honestly, and that it did not manufacture the result.
Correcting the pinning shrinks the gap by seven percentage points -- the artifact was working
**against** io_uring the whole time -- without changing any ordering or conclusion.

Establishes that the cache ceiling is a real lever and the wrong one. It lifts io_uring by 14.9%
(17,794 to 20,442) but lifts epoll by 25.1% (34,959 to 43,745), so the ratio gets *worse*, from 50.9%
to 46.7%. Whatever io_uring is doing, the 32 KB cache ceiling is not the whole of it.

Establishes the memory signature cleanly and with committed evidence: epoll's server pool is flat at
16 MB in every one of the fifteen epoll cell-runs, while io_uring's swings across a range wider than
10x in every one of its fifteen. That is [D14](D14-pooled-memory-measurement.md)'s finding,
reproduced with a log that survives.

Does **not** establish a stable epoll baseline. See the caveat below.

Does **not** test the cache ceiling above 256 KB. At 64 KB payload a 256 KB ceiling is comfortably
above the buffer size; that changes at 256 KB payload, which is what
[D20](D20-pinning-and-cache-ceiling-256kb.md) found, and what
[D21](D21-stacked-remediation.md) addresses by raising the ceiling to 1 MB.

## Raw data

- `benchmark-report/logs/pc64.log` -- five rounds, six cells, per-round detail including server pool
  ranges and client CPU counters
- `loadtest/scripts/thor-pincache.sh` -- the driver, with the pinning and cache-ceiling rationale in
  its header

**Verified against `benchmark-report/logs/pc64.log`.** Four of six medians match exactly; two are
corrected above.

## Caveats

- **The `ep-new` cell is unstable.** Its five rounds are 32,584 / 39,153 / 34,959 / 42,017 / 34,442 --
  a 29% spread, by far the widest of the six cells, and it is the denominator of the 50.9% corrected
  ratio. `ep-new-c` in the same rounds is tight (41,594 to 45,175, 8.6%). The corrected ratio should
  be treated as 47-52%, not as 50.9%.
- 64 KB and 2,000 connections only.
- The cache flag is applied to both client and server, so a one-sided effect cannot be separated.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared between client and server.
- Even the corrected pinning gives each side only two physical cores, and both sides still contend
  for last-level cache and memory bandwidth.
- Server pool is netty's `usedDirectMemory` accounting, not RSS.
- Every Part D test numbered D1 through D15 and D19 used the old pinning. This test says what that
  costs at 64 KB only.

## Related

- [D10](D10-payload-sweep-and-zero-copy.md) -- the single-run 64 KB row this replaces
- [D17](D17-mechanism-discriminator.md) -- the sweep that found the actual mechanism
- [D20](D20-pinning-and-cache-ceiling-256kb.md) -- the same sweep at 256 KB, with a different answer
- [D21](D21-stacked-remediation.md) -- the cache ceiling raised to 1 MB and combined with the receive
  buffer
- [C](C-harness-design.md) -- both pinning regimes and which tests used which
