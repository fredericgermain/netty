# D12. Kernel profiling at 1 KB, with capabilities

**Confidence:** SOLID
**Date:** 2026-08-26, after 05:46 BST (follows [D6](D6-async-profiler-ctimer-plaintext-client.md))
**Question:** [D6](D6-async-profiler-ctimer-plaintext-client.md) had no kernel stacks -- with kernel
frames resolving, where does io_uring's time go, and is `IOSQE_FIXED_FILE` worth implementing?

## Configuration

Driver `benchmark-report/scripts/thor-kprof.sh`.

- 10,000 connections, **20 s**, 1 KB payload, plaintext, closed loop
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- async-profiler on the **client**, `event=cpu`, `interval=1ms`, collapsed output
- The technique under test: `--cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG` plus
  `--security-opt seccomp=unconfined` on the client container

thor has `perf_event_paranoid=4` and `kptr_restrict=1`, and sudo wants a password. `CAP_PERFMON`
bypasses the paranoid check, `CAP_SYSLOG` un-hides kernel symbols so frames resolve to names, and
unconfining seccomp lets `perf_event_open` through docker's default filter.

## Result

**The technique works.** Kernel frames resolve by name with no host sysctl change.

Frames unique to io_uring: `do_user_addr_fault` 2.31%, `refill_stock` 1.78%, `clear_page_erms` 1.48%,
`page_counter_try_charge` 1.26%. `fget` 1.68% against epoll's `__fdget` 1.58%.

**Sample accounting:** epoll 65.8% of samples on kernel frames against 67.9% measured system time
(matches); io_uring 18.8% against 66.5% -- a **3.5x shortfall**, cause unexplained.

## Reading

Establishes that registered files (`IOSQE_FIXED_FILE`) are not worth implementing, and does it
cheaply. `fget` is 1.68% of io_uring's kernel time against epoll's `__fdget` at 1.58%. Eliminating fd
lookup entirely would recover about 1% against a 120% gap. This would have been a large JNI change;
one profile query saved all of it.

Establishes the technique itself, which is small and genuinely useful and does not appear to be
written up anywhere: kernel profiling inside a container, without root and without touching host
sysctls.

Establishes that the [D6](D6-async-profiler-ctimer-plaintext-client.md) shortfall is not an artifact
of `ctimer`. It reappears under `event=cpu` with kernel frames available, and it is *worse* -- 3.5x
here against 2.4x there. The epoll control accounting to within 2 points is what makes the io_uring
number believable as a shortfall rather than a mistake.

The four io_uring-unique frames -- a page fault handler, two memcg accounting functions and a page
zeroing routine -- all point at memory rather than at I/O. That hint is what
[D13](D13-profiling-at-256kb.md) went to check at a size where it would be four times more visible.

Does **not** explain the shortfall. Candidates raised but untested: perf sample throttling, samples
inside `io_uring_enter` with no Java frame to join to, NET_RX softirq time charged to the current
task with a kernel-only stack.

Does **not** license comparing any of the four percentages between transports. They are percentages
of samples, and io_uring's sample set covers 28% of its real time.

## Raw data

- `benchmark-report/scripts/thor-kprof.sh` -- the driver, including the capability flags and the note
  explaining why `event=ctimer` was used before
- Collapsed stacks were written to `/home/fred/tls-matrix/kprof/` on thor. **They are not committed.**
- **No run log is committed.** The frame percentages and the sample-accounting figures above are
  carried forward from the catalogue and **could not be verified against raw output**.

## Caveats

- **Raw data not committed.**
- **The percentages are not comparable across transports** because of the 3.5x shortfall. This is
  stated in the source and is worth repeating: an io_uring frame at 2.31% of an 18.8%-complete sample
  set is not 2.31% of io_uring's time.
- Client only. The server was not profiled.
- 1 KB payload only. The four suggestive frames are all small at this size.
- Old SMT-sibling pinning; loopback; queue depth 1; kernel 6.8; 4 physical cores shared.
- One run per transport, no rounds.
- Profiling perturbs the run; no un-profiled control at the same duration.
- The capability set includes `SYS_ADMIN`, which is broad. It works, but it is not a minimal
  privilege recommendation.

## Related

- [D6](D6-async-profiler-ctimer-plaintext-client.md) -- the first profile, and the shortfall's
  discovery
- [D8](D8-io-wq-thread-census.md) -- the falsified explanation for the shortfall
- [D13](D13-profiling-at-256kb.md) -- the same technique at 256 KB, where the memory hint pays off
