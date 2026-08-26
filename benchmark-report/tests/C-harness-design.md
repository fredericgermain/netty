# C. Load test harness design

**Confidence:** SOLID
**Date:** built and extended 2026-08-25 through 2026-08-26 (commits `655131094e` through
`28e0aed38b`)
**Question:** not a test. This records the harness every Part D result depends on, and the design
decisions that make those results mean what they say.

## Configuration

Standalone Maven project at `loadtest/`, **not** a netty module. Sources:
`LoadTest.java`, `Transports.java`, `Tls.java`, `Args.java`, `Counters.java`. Shaded to a single jar
and mounted read-only into containers.

Standard container flags used by every Part D script:

```
--network=host
--security-opt seccomp=unconfined     # docker's default seccomp blocks io_uring_setup
--ulimit nofile=65536:65536
--ulimit memlock=-1                   # needed for zero-copy cells
```

plus `SO_BACKLOG=8192` (`--backlog=8192`) and `--threads=4` on both sides.

Image is `eclipse-temurin:21-jdk-alpine` throughout except in
[D18](D18-glibc-control.md), which swaps it for `eclipse-temurin:21-jdk`.

Netty version: 4.2.18-SNAPSHOT.

## Result

Design decisions that matter for reproducibility:

- **Aborts, never falls back.** Netty defaults to NIO when a native transport is missing; this
  harness throws instead. Without this, an unavailable io_uring publishes NIO's number under
  io_uring's label and nothing in the output says so.
- **Two phases reported separately**: `RAMP` (connection establishment and handshakes) and `STEADY`.
- **Closed loop by default**, one request in flight per connection, and the output line says so
  (`mode=closed-loop:latency-is-queue-depth`) because p50 in that mode is queue depth, not service
  time.
- **Open loop via `--rate`**, measuring from *due* time to avoid coordinated omission. The output
  line reads `mode=open-loop:target-met` when the rate was actually achieved.
- **Counters from procfs and JMX**: `/proc/self/stat` fields 14/15 for user and system time; context
  switches summed over `/proc/self/task/*`, because the process file reports the main thread only and
  in netty the main thread does nothing after bind; `GarbageCollectorMXBean` for pauses.
- **Pool metrics**: `usedDirectMemory` and live chunk count on the server line
  (`SERVERCPU ... usedDirectMb=<n> pooledChunks=<n>`), added late, from
  [D13](D13-profiling-at-256kb.md) onward.
- **Port scanning.** Scripts scan `19990..20050` for a free port and wrap clients in `timeout`,
  after an orphaned process held 19999 for four hours and poisoned runs that merely looked slow.
  `benchmark-report/logs/load3.log` is the run that failed entirely before this existed; `load4.log`
  is the same script after, and opens with `using port 19990`.

Options added over time: `--ring-size`, `--buffer-ring`, `--buffer-ring-size`, `--zc-threshold`,
`--sndbuf`, `--rcvbuf-max`.

**Two pinning regimes exist and the distinction is load-bearing for every Part D result:**

| regime | server cpuset | client cpuset | used by |
|---|---|---|---|
| old, SMT siblings | `0-3` | `4-7` | D1-D15, D19 |
| corrected, whole cores | `0,1,4,5` | `2,3,6,7` | D16, D17, D18, D20, D21 |

On thor, `cpu0`'s thread siblings are `0,4`; likewise `1,5`, `2,6`, `3,7`. Four physical cores, eight
logical. The old regime therefore ran client and server as hyperthread siblings on the *same* four
physical cores while describing them as disjoint. Every script under
`benchmark-report/scripts/` uses the old regime; the corrected regime appears only in
`loadtest/scripts/`.

## Reading

Establishes what the numbers in Part D are numbers *of*. Three of the harness decisions above are
themselves findings and appear in `FINDINGS.md` as traps: the NIO fallback, the `SO_BACKLOG` default
of 200, and closed-loop p50 being queue depth.

Does **not** establish that the harness is correct. It has never been validated against an
independent load generator, and one instrument bug was found and is recorded in
[D8](D8-io-wq-thread-census.md).

## Raw data

- `loadtest/` -- the project, in this branch
- `loadtest/README.md` -- the running narrative
- `loadtest/scripts/thor-pincache.sh`, `thor-mech.sh`, `thor-stack.sh`, `thor-tlswarm.sh`,
  `thor-glibc.sh` -- the five sweeps using the corrected pinning
- `benchmark-report/scripts/thor-*.sh` -- eighteen earlier sweeps, all on the old pinning
- `benchmark-report/logs/load3.log` -- every cell `SERVER FAILED`, the run before port scanning
- `benchmark-report/logs/load4.log` -- the same script after, all cells succeed

`TESTS.md` previously said the earlier ad-hoc sweeps were "NOT committed" and existed only on thor.
That is now out of date in both directions: all eighteen are committed under
`benchmark-report/scripts/`, and the five corrected-pinning sweeps are committed under
`loadtest/scripts/`. The only scripts still missing are the profile post-processors other than
`stacks.sh`.

## Caveats

- **Loopback only.** The syscall epoll pays for is close to a memcpy, so io_uring's core advantage --
  amortising syscall entry -- has almost nothing to amortise. Unrepresentative of a real NIC.
- **Queue depth 1 per connection** in closed-loop mode. Universally described as io_uring's worst
  case.
- **Client and server share one 4-core machine.** Even under corrected pinning each side gets two
  physical cores, and they contend for last-level cache and memory bandwidth.
- **Kernel 6.8.0-57-generic.** Predates send-zc buffer coalescing and send/recv bundles (6.10) and
  `IORING_ENTER_NO_IOWAIT` (6.15).
- **One netty version**, 4.2.18-SNAPSHOT. One JDK major, 21.
- The harness reports the *client's* CPU counters on the `CLIENTCPU` line and the *server's* on
  `SERVERCPU`. Several early conclusions were withdrawn for reading a paired run's numbers as a
  property of one side -- see [D9](D9-cross-transport-2x2.md).

## Related

- [D1](D1-first-10k-connection-runs.md) -- the first run with this harness
- [D8](D8-io-wq-thread-census.md) -- an instrument bug in one census script
- [D15](D15-equal-rate-open-loop.md) -- the open-loop mode's decisive use
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the pinning correction, measured
