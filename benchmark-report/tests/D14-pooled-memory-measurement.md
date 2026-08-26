# D14. Pooled memory measurement

**Confidence:** SINGLE RUN per cell
**Date:** 2026-08-26, around 07:31 BST (commit `1669454637`)
**Question:** does the io_uring server actually hold more pooled direct memory, as
[D13](D13-profiling-at-256kb.md)'s sample counts suggest, and does a provided buffer ring fix it?

## Configuration

Driver `benchmark-report/scripts/thor-pool.sh`. Jar `loadtest-pool.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- **256 KB payload, 500 connections, 20 s**, plaintext, closed loop
- `--threads=4`, `--backlog=8192`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- `usedDirectMemory` and live chunk count sampled every 2 s from the server's `SERVERCPU` line
- Cells: epoll `--buffer-ring=0 --buffer-ring-size=2048`, io_uring `0 2048`,
  io_uring `512 --buffer-ring-size=65536`
- One run per cell

The mechanism under test, quoted from the script: a completion-based transport commits a receive
buffer when it *submits* the read, not when data becomes available, so it holds one per read in
flight rather than one per ready read.

## Result

| server | req/s | pooled memory across the run |
|---|---|---|
| epoll | 9,139 | 32 MB / 8 chunks, identical every sample |
| io_uring | 3,966 | 72, 76, 140, 44, 56, 40, 68, 80, 60, 80 MB (8-36 chunks) |
| io_uring + buffer ring | 4,176 | 76, 44, 44, 44, 52, 124, 128, 56, 40, 68 MB |

## Reading

Establishes the mechanism directly rather than by inference from sample counts. epoll's footprint is
*identical* at every one of ten samples -- the allocator reaches a working set in the first two
seconds and never touches the arena again. io_uring's swings between 40 MB and 140 MB continuously,
which is arena chunks being allocated and released throughout the run. That is the 7-against-1,201
sample ratio in [D13](D13-profiling-at-256kb.md), seen as memory.

Establishes that a provided buffer ring does **not** fix it. The prediction in the script was
explicit: a ring, where the kernel picks a buffer at completion time from a fixed pre-registered set,
should bring the footprint down. It does not -- the ringed run swings 40 MB to 128 MB, the same
shape, and throughput moves only from 3,966 to 4,176.

That negative result is worth as much as the positive one. It rules out "netty holds too many
buffers because the ring is not configured" and points instead at the *ceiling* on what the
thread-local cache will accept, which is what [D16](D16-pinning-and-cache-ceiling-64kb.md) tests.

Does **not** establish a causal direction between memory churn and throughput. The io_uring cells are
both slower *and* churning; nothing here separates the two. [D15](D15-equal-rate-open-loop.md) does,
by holding the rate fixed, and finds the churn disappears -- which reverses the causal arrow.

Does **not** confirm the buffer ring engaged. Same doubt as [D11](D11-buffer-rings-at-64kb.md); there
is no `isUsable()` assertion.

## Raw data

- `benchmark-report/scripts/thor-pool.sh` -- the driver, with the full mechanism hypothesis in its
  header comment
- **No run log is committed.** There is no `pool.log` in `benchmark-report/logs/`. The three req/s
  figures and all thirty memory samples are carried forward from the catalogue and **could not be
  verified against raw output**.
- The io_uring memory-churn signature is independently corroborated by `pc256.log`, which reports
  server pool ranges of 32-156 MB for io_uring against a flat 32-32 MB for epoll at the same payload
  and connection count -- see [D20](D20-pinning-and-cache-ceiling-256kb.md). Different run, same
  shape, and that one *is* committed.

## Caveats

- **Raw data not committed**, though the effect is corroborated by `pc256.log`.
- **One run per cell.** The throughput figures in particular have no spread; 3,966 against 4,176 is
  well inside the round-to-round variation seen elsewhere at this payload.
- Ten samples at 2 s intervals is a coarse view of a 20 s run.
- Old SMT-sibling pinning.
- 256 KB and 500 connections only.
- `usedDirectMemory` is netty's own accounting, not RSS. It says nothing about what the kernel has
  actually faulted in.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared.
- No `isUsable()` assertion on the buffer ring.

## Related

- [D13](D13-profiling-at-256kb.md) -- the profile that motivated this
- [D15](D15-equal-rate-open-loop.md) -- the control that shows the churn is a consequence, not a cause
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the cache-ceiling lever
- [D20](D20-pinning-and-cache-ceiling-256kb.md) -- committed pool ranges at the same payload
