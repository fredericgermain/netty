# D6. async-profiler `ctimer`, plaintext client

**Confidence:** SOLID
**Date:** 2026-08-26, around 05:46 BST (commit `c9921a78af`, "Profile the io_uring client: the cost is
completion handling, not syscalls")
**Question:** inside the client process, which frames are burning io_uring's extra CPU?

## Configuration

Driver `benchmark-report/scripts/thor-prof.sh`.

- 10,000 connections, **20 s**, 1 KB payload, plaintext, closed loop
- `--threads=4`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- async-profiler attached to the **client only**, via `-agentpath:.../libasyncProfiler.so`
- `event=ctimer` -- POSIX timers, no privileges required, and **no kernel stacks**
- Output as collapsed stacks

## Result

- epoll: 80,246 samples, **65.6% self-time in `/lib/ld-musl-x86_64.so.1`** (libc syscall stubs)
- io_uring: 33,398 samples, **no dominant frame**. 15.5% `syscall`, then `handleFastPath` 3.5%,
  `UnsafeRefArrayAccess.soRefElement` 2.3%, `scheduleWriteMultiple` 2.2%, `writeComplete0` 2.2%
- Context switches: io_uring 1,694 voluntary vs epoll 4,293. Batching works, and CPU per request is
  still higher.

**Caveat found by cross-checking, and it is the more durable result**: async-profiler under-sampled
io_uring by **2.4x** -- 33.4 s of samples for 79.7 s of measured CPU, where epoll matched almost
exactly at 80.2 s of samples for 78.5 s of CPU. The two profiles are not comparable as percentages.

## Reading

Establishes that io_uring's cost is not concentrated anywhere. epoll has a single 65.6% frame; io_uring
has a long tail with nothing above 15.5%. That is a bad basis for changing code, and it is why the
work moved to kernel profiling ([D12](D12-kernel-profiling-at-1kb.md)) and then to bigger payloads
([D13](D13-profiling-at-256kb.md)) rather than optimising a hot Java frame.

Establishes that the batching claim is true and insufficient: io_uring genuinely takes 2.5x fewer
voluntary context switches, and is still slower.

Establishes the instrument caveat that outlived the experiment. Nothing in async-profiler's output
says it is missing half the time. The rule this produced -- check profiler sample totals against CPU
counters before quoting any percentage -- is worth more than the profile.

Does **not** show kernel frames at all. `event=ctimer` cannot. Every percentage here is of *sampled*
time, and for io_uring that is 42% of the real time.

Does **not** profile the server. Client only.

## Raw data

- `benchmark-report/scripts/thor-prof.sh` -- the driver, with the `event=ctimer` choice
- Collapsed stacks were written to `/home/fred/tls-matrix/prof/` on thor. **They are not committed.**
  No log in `benchmark-report/logs/` contains the sample counts, the frame percentages or the context
  switch figures quoted above.
- `benchmark-report/scripts/stacks.sh` post-processes collapsed stacks, but it reads
  `/home/fred/tls-matrix/bigprof/`, the [D13](D13-profiling-at-256kb.md) output, not this run's.

**The numbers in this file could not be verified against committed output.** They are carried forward
from the catalogue unchanged. Recovering `prof/*.collapsed` from thor would settle them.

## Caveats

- **Raw data not committed.** See above.
- `event=ctimer` gives no kernel stacks, so this profile can only ever see the Java and libc side.
- The 2.4x sampling shortfall means io_uring's percentages are percentages of an unrepresentative
  42% sample. Do not compare a frame's share across the two transports.
- Client only; old SMT-sibling pinning; 1 KB payload; loopback; queue depth 1; kernel 6.8; 4 physical
  cores shared.
- One run per transport, no rounds.
- Profiling perturbs the run. No un-profiled control was taken at the same 20 s duration.

## Related

- [D8](D8-io-wq-thread-census.md) -- the leading explanation for the shortfall, falsified
- [D12](D12-kernel-profiling-at-1kb.md) -- the same question with kernel frames, and the shortfall
  re-measured at 3.5x
- [D13](D13-profiling-at-256kb.md) -- the profile that did find a signature
