# D8. io_wq thread census

**Confidence:** SOLID
**Date:** 2026-08-26, between 05:46 and 06:19 BST (between commits `c9921a78af` and `c47f10147c`)
**Question:** is async-profiler's missing io_uring time being burned in `iou-wrk-*` kernel worker
threads, which a JVM profiler never attaches to?

## Configuration

Driver `benchmark-report/scripts/thor-iowq.sh`.

- 10,000 connections, **20 s**, 1 KB payload, plaintext, closed loop
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- Both transports, both sides
- Census taken during steady state by reading thread names out of `/proc/<pid>/task/*/comm`, plus
  fields 14/15 of `/proc/<tid>/stat` for CPU
- epoll is the control: it has no worker threads by construction, so it must show none

## Result

**No `iou-wrk-*` threads at all**, on either transport, on either side. Operations complete inline;
nothing is punted to io_wq.

This falsified the leading explanation for the profiler shortfall in
[D6](D6-async-profiler-ctimer-plaintext-client.md).

**Instrument bug, recorded honestly:** the census script's CPU columns were mislabelled by a
one-field offset in `/proc/<tid>/stat` parsing. The thread **names**, which is what the test was for,
are correct. **The CPU figures from that script were never used** anywhere in this work.

## Reading

Establishes that the punt-to-io_wq story is wrong, and it is a strong falsification: the hypothesis
predicted the existence of named threads, and the threads do not exist. epoll as a control confirms
the census can see thread names at all.

This matters beyond the profiler question. Punting to a worker would mean the operation is *not*
being completed inline, which is the whole point of the ring, and it would cost a thread handoff per
operation. That would have been a finding. It is not happening.

Does **not** explain where the time goes. The shortfall remains unexplained; see
[D12](D12-kernel-profiling-at-1kb.md), where it is re-measured at 3.5x and the candidates -- perf
sample throttling, samples inside `io_uring_enter` with no Java frame to join to, NET_RX softirq time
charged to the current task with a kernel-only stack -- are listed but untested.

Does **not** rule out kernel work outside the process's thread list entirely. io_wq threads are the
ones that *would* appear; softirq context would not.

## Raw data

- `benchmark-report/scripts/thor-iowq.sh` -- the driver, including the comment explaining why io_wq
  was the candidate and why epoll is the control
- **No run log is committed.** There is no `iowq.log` in `benchmark-report/logs/`. The census result
  is carried forward from the catalogue and **could not be verified against raw output**.

## Caveats

- **Raw data not committed.**
- **The script's CPU columns are wrong** by a one-field offset. Anyone re-reading this script's output
  must ignore those columns. The thread-name result is unaffected.
- One workload point: 1 KB, 10k connections, plaintext, 20 s.
- Old SMT-sibling pinning; loopback; queue depth 1; kernel 6.8; 4 physical cores shared.
- A census is a sample in time. It was taken during steady state, but bursty punting between samples
  would not be seen.
- Kernel 6.8. io_wq punting behaviour is kernel-version dependent.

## Related

- [D6](D6-async-profiler-ctimer-plaintext-client.md) -- the shortfall this was meant to explain
- [D12](D12-kernel-profiling-at-1kb.md) -- the shortfall re-measured with kernel frames available
