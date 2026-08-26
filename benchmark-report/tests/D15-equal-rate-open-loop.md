# D15. Equal-rate open loop, the decisive control

**Confidence:** SINGLE RUN per cell, but the cleanest comparison in the whole branch
**Date:** 2026-08-26, around 07:31 BST (commit `1669454637`)
**Question:** at equal load rather than at saturation, is io_uring intrinsically more expensive per
operation?

## Configuration

Driver `benchmark-report/scripts/thor-equal.sh`. Jar `loadtest-pool.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- **256 KB payload, 500 connections, 20 s**, plaintext
- **Open loop, `--rate=2000`** on both transports. Latency measured from *due* time, so coordinated
  omission is avoided.
- `--threads=4`, `--backlog=8192`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- `usedDirectMemory` and live chunk count sampled from the server
- One run per transport

Both cells met the 2,000 req/s target exactly, which is the precondition that makes the CPU
comparison legitimate: identical work in, so per-request CPU is comparable.

## Result

| server | user us/req | system us/req | total | pooled |
|---|---|---|---|---|
| epoll | 76.2 | 127.5 | **203.7** | 16 MB / 4 chunks, flat |
| io_uring | 86.0 | 117.1 | **203.1** | 32 MB / 8 chunks, flat |

**io_uring is not intrinsically more expensive per operation** at equal load: 203.1 against 203.7 us
per request, a 0.3% difference. And the chunk thrashing disappears -- both footprints are flat.

What survives is a stable **2x memory footprint**.

## Reading

This is the control that reframes the entire io_uring story, and it does it by removing one variable.
At saturation ([D13](D13-profiling-at-256kb.md)) io_uring costs 968 us/req against epoll's 468. At
2,000 req/s it costs 203.1 against 203.7. The transport did not become efficient; the *load* changed.

It also reverses the causal arrow on [D14](D14-pooled-memory-measurement.md). The memory churn is not
what makes io_uring slow. Both footprints are flat here, so the churn is a **consequence** of running
at saturation with a footprint that will not fit the thread-local cache, not a cause of the deficit.

Note the split: io_uring spends more in user space (86.0 against 76.2) and less in the kernel (117.1
against 127.5), and the two nearly cancel. That is the completion-handling-versus-syscall trade
working exactly as advertised -- at a load where there is headroom to absorb it.

Does **not** explain the saturation deficit. It says the per-operation cost is equal at 2,000 req/s
and unequal at 4,000-8,000. Something is non-linear, and this test does not say what.

Does **not** have error bars. **This single pair carries a lot of the argument and it is one run per
cell.** It is the most under-measured important result in the branch.

## Raw data

- `benchmark-report/scripts/thor-equal.sh` -- the driver, confirming `RATE=2000`, `PAY=262144`,
  `CONNS=500`, `DUR=20` and the old pinning
- **No run log is committed.** There is no `equal.log` in `benchmark-report/logs/`. Both CPU rows and
  both pool figures are carried forward from the catalogue and **could not be verified against raw
  output**.

## Caveats

- **Raw data not committed.**
- **One run per cell, no rounds, no spreads.** Worth repeating with rounds; 203.1 against 203.7 is a
  difference far smaller than any spread measured anywhere else in Part D, so the "no difference"
  conclusion is safe, but the absolute values are not.
- One rate. 2,000 req/s is roughly half epoll's saturation and roughly half io_uring's. A rate sweep
  would show where the curves diverge and was never run.
- Old SMT-sibling pinning.
- 256 KB and 500 connections only.
- Loopback, kernel 6.8, 4 physical cores shared.
- Open-loop mode has its own unexplained anomaly at small payloads -- p50 around 100 us against p99
  around 1 s with the target rate met, visible in `benchmark-report/logs/load4.log` section C. That
  anomaly is at 1 KB, not at this payload, but the mode is the same and it is not understood.

## Related

- [D13](D13-profiling-at-256kb.md) -- the same cell at saturation
- [D14](D14-pooled-memory-measurement.md) -- the churn this shows to be a consequence
- [D17](D17-mechanism-discriminator.md) -- the per-read mechanism that is non-linear in load
- [C](C-harness-design.md) -- the open-loop mode
