# D10. Payload sweep and zero-copy send

**Confidence:** SINGLE RUN per cell
**Date:** 2026-08-26, around 07:09 BST (commit `dd16437461`, "Sweep message size and zero-copy send:
io_uring has a cliff, not a sweet spot")
**Question:** at what message size does io_uring stop losing, and can `IORING_OP_SEND_ZC` make it
win?

## Configuration

Driver `benchmark-report/scripts/thor-payload.sh`. Jar `loadtest-zc.jar`, image
`eclipse-temurin:21-jdk-alpine`, 10 s per cell, `--threads=4`.

**Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`.

Connections scale down as payload rises so total bytes in flight stays sane. The zero-copy threshold
is set just below the payload so `SEND_ZC` actually engages for that row:

| payload | connections | `--zc-threshold` for the zc cell |
|---|---|---|
| 1024 | 10,000 | 512 |
| 8192 | 10,000 | 4096 |
| 65536 | 2,000 | 32768 |
| 262144 | 500 | 131072 |

The non-zc cells pass `-1`, which disables the option. `--ulimit memlock=-1` is set for the zero-copy
cells.

## Result

| payload | conns | epoll | io_uring | io_uring + SEND_ZC |
|---|---|---|---|---|
| 1 KB | 10,000 | 137,671 | 119,917 | 70,156 |
| 8 KB | 10,000 | 115,997 | 86,717 | 50,535 |
| 64 KB | 2,000 | 38,914 | 18,137 | 18,374 |
| 256 KB | 500 | 9,259 | 3,767 | 3,813 |

io_uring as a percentage of epoll: 87%, 75%, 47%, 41%.

## Reading

Establishes the central surprise of the whole branch: **the deficit widens with message size**.
Published io_uring benchmarks say it should narrow. liburing issue #536, the most-cited
io_uring-vs-epoll network benchmark, shows io_uring going from 32% of epoll at 64 B to 82% at 16 KB.
This curve runs the other way.

Establishes that zero-copy send is **actively harmful below 64 KB** -- 70,156 against 119,917 at
1 KB, 50,535 against 86,717 at 8 KB -- and break-even at 64 KB and above. This is expected on kernel
6.8, which predates the 6.10 send-zc buffer coalescing; Axboe puts the post-6.10 crossover near 3000
bytes. It should be reported as a property of *this kernel*, not of io_uring.

Does **not** establish the magnitudes. One sample per cell, twelve cells, no spreads anywhere. The
64 KB row was later reproduced across many interleaved rounds -- see
[D16](D16-pinning-and-cache-ceiling-64kb.md) and [D17](D17-mechanism-discriminator.md) -- so the
shape is safe. **The 8 KB and 256 KB rows were never re-run** and have no error bars.

Does **not** separate payload from connection count. Both change together down the table, by design,
and the two are confounded. A 500-connection 1 KB row would have separated them and was never run.

## Raw data

- `benchmark-report/scripts/thor-payload.sh` -- the driver, confirming every payload, connection count
  and zc threshold above
- **No run log is committed.** There is no `payload.log` in `benchmark-report/logs/`. All twelve
  figures are carried forward from the catalogue and **could not be verified against raw output**.
- The 256 KB rows are partially corroborated by later runs on the same cell: `pc256.log` gives epoll
  8,604 and io_uring 3,878 under the same old pinning ([D20](D20-pinning-and-cache-ceiling-256kb.md)),
  against 9,259 and 3,767 here. Same magnitude, different run.
- The 64 KB rows are corroborated by `pc64.log` (epoll 41,504, io_uring 18,139 old pinning), which is
  **7% above** this run's epoll figure of 38,914 and 0.01% from its io_uring figure of 18,137.

## Caveats

- **One sample per cell.** No spreads. Two of the four rows were never re-run.
- **Old SMT-sibling pinning**, which [D16](D16-pinning-and-cache-ceiling-64kb.md) showed works against
  io_uring by about seven percentage points of ratio. The percentages above are therefore slightly
  worse for io_uring than corrected pinning would give.
- Payload and connection count vary together; they are confounded.
- **Kernel 6.8 is load-bearing for the zero-copy row.** Do not publish it as an io_uring property.
- Loopback, queue depth 1, 4 physical cores shared between client and server.
- Zero-copy applied on both sides.
- `req/s` is not the comparable unit once payload varies. The script also logs MB/s to
  `/tmp/p-detail.log`, which is not committed.

## Related

- [D11](D11-buffer-rings-at-64kb.md) -- the follow-up that asked the buffer-ring question at the right
  size
- [D13](D13-profiling-at-256kb.md) -- profiling the worst cell in this table
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the 64 KB row re-run properly, both pinnings
- [D17](D17-mechanism-discriminator.md) -- why the curve runs this way
- [D20](D20-pinning-and-cache-ceiling-256kb.md) -- the 256 KB row re-run properly
