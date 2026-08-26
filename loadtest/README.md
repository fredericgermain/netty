# netty TLS load test

A load generator for many concurrent connections, separate from the JMH benchmarks in
`microbench/`. JMH measures per-operation cost in one process; this runs a live client and server
so the transport axis (NIO / epoll / io_uring) has something to say. Bulk transfer over a handful
of connections issues so few syscalls that all three measure identically.

Not a module of the netty reactor. Build it on its own:

```sh
mvn -f loadtest/pom.xml package -Dnative.classifier=linux-x86_64
```

## Two phases, two modes

**Phases.** `ramp` opens every connection and completes every TLS handshake, reporting
connections/s -- with TLS this dominates setup and is a more realistic handshake figure than an
in-memory engine pair gives, because it includes accept, the event loop and real sockets.
`steady` then drives traffic for a fixed duration.

**Modes, and this decides whether the latency numbers mean anything.** Without `--rate` the steady
phase is a closed loop: every connection sends as fast as it can. That finds maximum throughput,
but Little's Law then fixes p50 at roughly connections/throughput regardless of how fast the stack
is -- at 10k connections that is tens of milliseconds and is a restatement of the concurrency you
chose. With `--rate` it is an open loop at a fixed offered rate, latency is measured from when each
request was *due* rather than when it was sent (coordinated omission), and the percentiles are
real. The output states which mode produced them, and for an open loop whether the target was met;
a missed target prints `percentiles-invalid`.

Measured on the same server, 200 connections, BoringSSL: closed loop 81,987 req/s with p50 1831us;
open loop at 20k/s, 19,995 req/s with p50 60us. Thirty times apart, and only the second is a
service time.

## Things that abort rather than going quiet

A benchmark that silently measures something else is worse than one that fails.

- An unavailable native transport aborts instead of falling back to NIO, which is netty's default
  and would publish NIO's number under epoll's label.
- `--tls=openssl` aborts when tcnative is not loaded, rather than letting `SslProvider.OPENSSL`
  resolve to whatever happens to be on the classpath.
- `-Dnetty.loadtest.tls.groups` pins the key exchange group. A TLS 1.3 suite does not name its key
  exchange, so left alone BoringSSL negotiates a post-quantum hybrid while a TLS 1.2 run does
  classical ECDHE -- a ~33% difference attributed to the wrong thing.

## Operational notes that cost real time to find

- `SO_BACKLOG` defaults to 8192 here, not netty's 200. Ten thousand simultaneous connects overflow
  200 instantly, the kernel drops SYNs, and the ramp appears to stall rather than to fail.
- Docker's default seccomp profile **blocks `io_uring_setup`**. Without
  `--security-opt seccomp=unconfined` the io_uring cells cannot start. netty's own compose files
  carry this for the same reason.
- A client hung in shutdown once outlived its container by four hours holding the port, after which
  every later cell reported "SERVER FAILED" with no clue why. Pick a port you have just confirmed
  free, and bound the client with `timeout`.
- 10k connections is ~20k descriptors per side: `--ulimit nofile=65536:65536`.

## What it has measured

x86_64, 8 cores, client and server pinned to disjoint 4-core sets, five interleaved rounds.
Interleaved specifically so drift in machine state cannot map onto the transport axis -- grouping
all of one transport then all of the other would put drift exactly where the variable under test
lives.

**epoll is ~32% faster than io_uring on plaintext**, and that is robust: medians 152,227 against
114,980 req/s, tight spreads, no overlap.

The counters say where it goes, in microseconds of CPU per request (medians):

| | client utime | client stime | server utime | server stime |
|---|---|---|---|---|
| epoll | 8.40 | 15.34 | 5.90 | 15.49 |
| io_uring | 13.53 | 20.13 | 6.28 | **12.80** |

The two ends disagree, and that is the finding. **On the server io_uring does what it promises**:
12.80us of kernel time per request against epoll's 15.49, a 17% saving, with roughly a third the
context switches. **On the client it costs 61% more user CPU and 31% more kernel time.** Same
transport, same ring size, same machine, opposite result -- so the deficit is not io_uring in
general but netty's client-side path.

The profiles agree. Under `event=ctimer`:

- epoll spends **65.6% of its samples inside `ld-musl-x86_64.so.1`** -- libc syscall stubs. It is a
  syscall-bound workload doing exactly that.
- io_uring has **no dominant frame**: 15.5% in `syscall` and then a long tail of completion-path
  Java frames at 1-3.5% each (`handleFastPath`, `writeComplete0`, `scheduleWriteMultiple`, jctools
  queue accessors). Death by a thousand cuts in completion handling rather than one hot spot.

### A caveat worth more than the result

async-profiler **under-sampled io_uring by 2.4x**. epoll produced 80,246 samples at 1ms for 78.5s
of measured CPU -- a near-exact match, which validates the method. io_uring produced 33,398 samples
for 79.7s of CPU, so roughly 58% of its CPU time is missing from the profile, almost certainly time
inside `io_uring_enter` that SIGPROF cannot attribute.

So the io_uring percentages above understate its kernel portion, and the two profiles are not
directly comparable as percentages. Without cross-checking sample totals against the CPU counters,
the profile would have looked authoritative and been wrong -- which is why the cheap counters were
built first and the profiler pointed second.

### Not established

The TLS ordering. io_uring's TLS rounds trend upward across the run -- 70,442, 82,764, 111,042,
115,721, 115,189 -- with CPU per request falling in step, while epoll's show no trend. Each round
is a fresh JVM, so this is not JIT, and until it is explained the medians cannot be compared.

The GC hypothesis for the TLS variance is **falsified**: `gcMs` stays between 71 and 99 while
throughput swings from 70k to 116k, and epoll's slowest TLS round had its lowest GC.
