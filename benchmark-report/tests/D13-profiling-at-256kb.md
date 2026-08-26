# D13. Profiling at 256 KB, both sides

**Confidence:** SINGLE RUN
**Date:** 2026-08-26, around 07:31 BST (commit `1669454637`, "Root-cause the size cliff: a
memory-footprint feedback loop")
**Question:** at 256 KB, where io_uring is at its worst, does the cost have a signature the 1 KB
profile could not show?

## Configuration

Driver `benchmark-report/scripts/thor-big-prof.sh`. Jar `loadtest-zc.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- **256 KB payload, 500 connections, 20 s**, plaintext, closed loop
- `--threads=4`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- async-profiler on **both** client and server, `event=cpu`, `interval=1ms`, collapsed output
- Kernel frames enabled via `--cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG` plus
  `seccomp=unconfined`, the [D12](D12-kernel-profiling-at-1kb.md) technique
- Output to `/home/fred/tls-matrix/bigprof/{epoll,io_uring}-{client,server}.collapsed`
- One run per transport

## Result

Both transports CPU-saturated at ~78 core-seconds, so this is a clean same-CPU comparison: **epoll
8,367 req/s at 468 us/req, io_uring 3,877 at 968 us/req.**

Per-request sample ratios (io_uring over epoll): `jlong_disjoint_arraycopy` 1.77x,
`Copy::fill_to_memory_atomic` 2.32x, kernel `rep_movs_alternative` 0.85x. io_uring does **less**
kernel copying and **more** userspace zeroing.

Stack walk found two distinct sources of the zeroing:

- **client-side fill is the load generator's own payload construction** (`RequestLoop.sendClosed ->
  writeZero`), identical work in both transports, **not netty**
- **server-side is netty**: `PoolArena$DirectArena.newChunk -> ByteBuffer.allocateDirect`,
  **7 samples on epoll, 1,201 on io_uring**

## Reading

Establishes the mechanism's fingerprint. 7 against 1,201 samples in fresh-arena-chunk allocation is
not a 2x difference, it is a categorical one: the epoll server allocates its arena chunks once and
reuses them; the io_uring server allocates continuously throughout the run.

Establishes that both sides being CPU-saturated at the same total makes the throughput comparison
mean something specific -- io_uring is doing 2.07x more CPU work per request, not merely being
scheduled worse.

Establishes the trap that the client-side zeroing is a red herring. Half the `fill_to_memory_atomic`
signal belongs to the load generator, does identical work in both cells, and would have been
attributed to netty without the stack walk. Walking the stack, rather than reading the flat profile,
is what separated them.

Does **not** establish a rate. Samples are not a rate, and the two runs have different durations of
useful work. That is exactly why [D14](D14-pooled-memory-measurement.md) exists: it measures
`usedDirectMemory` and live chunk count directly instead of inferring from sample counts.

Does **not** have error bars. One run per transport.

## Raw data

- `benchmark-report/scripts/thor-big-prof.sh` -- the driver
- `benchmark-report/scripts/stacks.sh` -- **the stack-extraction script for this run.** It reads
  `/home/fred/tls-matrix/bigprof/*.collapsed` and prints the top two `Unsafe_SetMemory0` stacks per
  file. This is the script that produced the two-source finding above.
- Collapsed stacks in `/home/fred/tls-matrix/bigprof/` on thor. **Not committed.**
- **No run log is committed.** The throughput, us/req, sample ratios and the 7-against-1,201 figures
  are carried forward from the catalogue and **could not be verified against raw output**.

**Correction to the catalogue.** `TESTS.md` said "`stack64.log` and `stack256.log` on thor contain
further stack extracts that were never read". That is wrong on both counts. Those two logs are
committed in `benchmark-report/logs/`, they have now been read, and **they are not stack extracts at
all** -- they are five-round throughput sweeps of a stacked remediation, produced by
`loadtest/scripts/thor-stack.sh`. They are written up as [D21](D21-stacked-remediation.md). No further
stack extract from this run exists anywhere.

## Caveats

- **Raw data not committed**, and the profile output is the entire content of this test.
- **One run per transport, no rounds, no spreads.**
- Old SMT-sibling pinning. 256 KB and 500 connections were never re-run under corrected pinning with
  profiling, though [D20](D20-pinning-and-cache-ceiling-256kb.md) covers the throughput side.
- The 3.5x async-profiler shortfall from [D12](D12-kernel-profiling-at-1kb.md) applies here too; at
  256 KB it was about 30%. Percentages are still not comparable across transports, only ratios of
  the same frame after normalising per request -- which is what the sample-ratio row does, and why it
  is expressed that way.
- Sample counts, not rates. See above.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared.
- Profiling perturbs the run; no un-profiled control at the same duration.

## Related

- [D12](D12-kernel-profiling-at-1kb.md) -- the technique, and the memory hint that led here
- [D14](D14-pooled-memory-measurement.md) -- the same mechanism measured as memory rather than samples
- [D15](D15-equal-rate-open-loop.md) -- the control that shows the churn disappears at equal load
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the cache-ceiling lever this suggested
- [D21](D21-stacked-remediation.md) -- what `stack64.log` and `stack256.log` actually contain
