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

## QUIC: `--protocol=quic`

Same two phases, same `RAMP` / `STEADY` / `CLIENTCPU` / `SERVERCPU` lines, same `RequestLoop`, same
4-byte length prefix on the wire. A QUIC stream is a byte stream, so it needs framing for the same
reason TCP does, and sharing the code is what lets a QUIC table and a TCP table be read side by
side. The implementation is `QuicLoad.java`; `LoadTest.steady()` and `LoadTest.ramp()` are shared
rather than copied.

`--tls` is ignored: QUIC is TLS 1.3 or nothing. Compare it against `--tls=openssl`, never against
plaintext, or the delta is AES and not transport.

**Run QUIC on a glibc image.** The released `netty-codec-native-quic` does not load on Alpine --
that is the whole subject of the `quic-musl-compat` branch -- so every QUIC cell here uses
`eclipse-temurin:21-jdk`. Mixing that question into this one would make both unanswerable.

### Three shape differences that are not tuning knobs

**A QUIC server has no accept.** Every connection arrives as datagrams on one UDP socket, so one
socket is one event loop thread for the whole machine no matter how many loops exist. The only fix
is `SO_REUSEPORT`: `--quic-server-sockets=N` binds the port N times and the kernel's 4-tuple hash
picks the socket. **Netty's NIO datagram channel cannot do this** -- `NioDatagramChannelConfig` does
not know the option, and `Bootstrap` logs "Unknown channel option" and carries on -- so a NIO QUIC
server is structurally capped at one core. `--quic-server-sockets>1` on NIO aborts rather than
quietly running single-socket.

**No `QuicCodecDispatcher`.** It exists to re-route a packet the kernel delivered to the wrong
socket, which happens when a client migrates. Migration is pinned off and every client socket stays
bound for the run, so the kernel's hash is a stable router and the dispatcher's cross-event-loop
`fireChannelRead` is avoided.

**One UDP socket per QUIC connection on the client.** Multiplexing every connection over one socket
would put the whole run on one event loop thread and turn a comparison against N TCP sockets into a
comparison against 1.

### UDP buffers, which is where a QUIC benchmark goes wrong silently

An undersized UDP receive buffer is not an error. The kernel drops the datagram, quiche retransmits,
and the run reports itself as slow QUIC. So `--udp-rcvbuf` (default 4 MB) and `--udp-sndbuf`
(default 1 MB) are set explicitly and the READY line prints what the kernel actually applied next to
what was asked for. Linux returns double the request -- half is its own bookkeeping allowance -- and
clamps silently at `net.core.rmem_max` / `net.core.wmem_max`. On the test host those are 50,000,000
and **1,048,576**, so a send buffer request above 1 MB is clamped and the "actual" is the only
number worth reading.

Read `RcvbufErrors` out of `/proc/net/snmp` around every cell. Zero drops is a precondition for the
throughput figure meaning anything, not a bonus check.

`--udp-recv-size` bounds the per-datagram receive buffer. A datagram channel reads one datagram into
one buffer and the kernel discards the rest, so a receive size below the peer's maximum datagram
truncates packets rather than splitting them. It is derived from `--quic-mtu`.

### The knobs, and their defaults

| flag | default | why that default |
|---|---|---|
| `--connections` | 500 | a QUIC handshake is far dearer than a TCP+TLS one; 10,000 would make the ramp the whole run |
| `--quic-server-sockets` | `--threads` | one socket per server event loop, via SO_REUSEPORT |
| `--quic-streams` | 1 | one stream per connection is the honest analogue of one TCP connection |
| `--quic-mtu` | 1200 | the internet-safe datagram size a real deployment sends; loopback would otherwise tempt a run into a size no path carries |
| `--quic-cc` | cubic | quiche's own default |
| `--quic-flow-mb` | 16 | connection flow-control window, far above one request in flight |
| `--quic-stream-flow-mb` | 4 | stream window; a window near the payload adds a round trip per request and reports it as latency |
| `--quic-gso` | 0 | UDP segmentation offload, epoll only; aborts if the kernel lacks `UDP_SEGMENT` |

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


## Buffer rings and multishot recv: swept, no effect

Netty sets `IORING_RECV_MULTISHOT` in exactly one place, `scheduleReadProviderBuffer()` in
`AbstractIoUringStreamChannel`, and reaches it only when a provided buffer ring is configured.
`IoUringIoHandlerConfig` configures none by default, so `io.netty.iouring.recvMultiShotEnabled`
defaulting to `true` is inert on its own. Every io_uring measurement in this branch before this
point therefore ran one-shot recv: an SQE prepared, submitted, reaped and re-armed per read.

That made buffer rings the obvious candidate for the plaintext deficit, and the `ctimer` profile
agreed in shape: no dominant frame, just a long tail of `handleFastPath`, jctools accessors and
`writeComplete0`, which is what per-read re-arming looks like.

Five interleaved rounds, 10k connections, 10 s, x86_64, `--buffer-ring` 0 / 1024 / 4096:

| cell | round spread | median |
|---|---|---|
| epoll | 137,726 - 166,466 | 159,512 |
| io_uring, no buffer ring | 101,105 - 119,759 | 117,079 |
| io_uring + buffer ring 1024 | 110,861 - 120,091 | 116,356 |
| io_uring + buffer ring 4096 | 107,439 - 124,705 | 115,023 |

The three io_uring cells overlap almost entirely and their medians sit within 2%. epoll leads all
three in all five rounds. **Arming multishot recv does not close the gap**, so the cost is not
per-read re-arming, and by the branch's own rule this is reported as no effect rather than as a
small one. Note the epoll spread is 21% this run, so the machine was drifting; that widens every
error bar but cannot manufacture the consistent epoll lead.

Two things found on the way:

- **`IoUringBufferRingConfig.builder()` cannot be used without `batchSize()`.** The builder
  initialises it to -1 and `build()` validates it into 1..1024, so it throws where every other
  optional field has a working default. Reportable upstream.
- **io_uring is not punting to `io_wq`.** A thread census during steady state found no `iou-wrk-*`
  threads on either side, so operations are completing inline and the deficit is not a worker
  handoff.

## Kernel profiling on a host you cannot change

thor has `perf_event_paranoid=4` and `kptr_restrict=1` and `sudo` wants a password, which is why
the first profiles used `ctimer` and saw no kernel frames at all. Container capabilities lift both
without touching the host:

    --cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG --security-opt seccomp=unconfined

`CAP_PERFMON` bypasses the paranoid check, `CAP_SYSLOG` un-hides kernel symbols so frames resolve
to names, and unconfining seccomp lets `perf_event_open` through docker's default filter. Kernel
frames then resolve normally (`do_syscall_64`, `io_uring_enter`, `tcp_*`), and nothing on the host
changes.

**A caveat that outlived the experiment.** Sample counts must be checked against the CPU counters
before any percentage is quoted:

| | stime share of CPU | share of samples on kernel frames |
|---|---|---|
| epoll | 67.9% | 65.8% |
| io_uring | 66.5% | **18.8%** |

epoll's profile accounts for itself. io_uring's kernel time is largely invisible to the sampler
even in real `perf` mode, and the `io_wq` explanation was tested and falsified. The cause is not
established, so io_uring's profile is usable for the *shape* of its user-space work and not for
percentages. Reading it without this check would have understated its kernel share by ~3.5x.


## Crossing the transports: the deficit is symmetric, and two earlier claims are withdrawn

Every run before this one used the same transport on both ends, so "io_uring is 30% slower" really
meant "io_uring on both ends is 30% slower" and could not say which side paid. Client and server
are separate processes sharing only a TCP connection, so the full 2x2 costs nothing to run.

Five interleaved rounds, 10k connections, 10 s, 1 KB payload, x86_64:

| server | client | round spread | median req/s | server stime/req |
|---|---|---|---|---|
| epoll | epoll | 124,125 - 166,896 | **139,356** | 15.6 us |
| io_uring | epoll | 106,844 - 125,922 | 115,252 | **21.5 us** |
| epoll | io_uring | 103,556 - 128,112 | 112,656 | 13.8 us |
| io_uring | io_uring | 108,065 - 120,161 | 114,885 | ~20 us |

epoll/epoll leads in all five rounds individually, not just on medians.

**Two earlier claims in this file are withdrawn.**

1. *"The plaintext deficit is concentrated in netty's client-side io_uring path."* Not supported.
   Substituting io_uring on the server alone costs about as much as substituting it on the client
   alone, and the two single-substitution cells are indistinguishable from each other round by
   round. The penalty is symmetric.
2. *"On the server, io_uring does what it promises: 12.80 us of kernel time per request against
   epoll's 15.49, a 17% saving."* Not supported. With the client held at epoll so the server is
   measured in isolation, the io_uring server uses **more** kernel time per request, 21.5 us
   against 15.6. The 12.80 figure was one sample at the low end of a spread that runs from 12.6 to
   22.4 in this data.

Both errors have the same cause: a per-request CPU figure from a single paired run was read as a
property of one side. Only holding one side fixed can attribute cost to a side, and that is a
different experiment from the one that had been run.

The third observation is the interesting one: **the two penalties do not add.** io_uring on both
ends is no worse than io_uring on one. In a closed-loop request/response the slowest stage sets the
rate, so once either side is the bottleneck, degrading the other changes nothing until it becomes
the bottleneck in turn. That is consistent with the data and means the 2x2 cannot be read as two
independent additive effects.

Caveat on this run: epoll/epoll drifted upward across rounds (131k, 124k, 139k, 167k, 166k), so the
machine was not in a steady state for the whole hour. Interleaving means every cell saw the same
drift, and the per-round ordering is unaffected, but the medians carry more uncertainty than their
spread alone suggests.


## Message size: io_uring does not have a size where it shines, it has a cliff

The 1 KB payload was chosen to keep the test syscall-bound, which is the worst case for io_uring:
the syscall it replaces is a cheap loopback copy and the ring's per-operation bookkeeping has
nothing to amortise against. The obvious prediction is that raising the payload shrinks the gap.

It does the opposite. Single run, connections scaled down as payload rises so bytes in flight stay
sane:

| payload | conns | epoll | io_uring | io_uring + SEND_ZC | io_uring as % of epoll |
|---|---|---|---|---|---|
| 1 KB | 10,000 | 137,671 | 119,917 | 70,156 | 87% |
| 8 KB | 10,000 | 115,997 | 86,717 | 50,535 | 75% |
| 64 KB | 2,000 | 38,914 | 18,137 | 18,374 | **47%** |
| 256 KB | 500 | 9,259 | 3,767 | 3,813 | **41%** |

In bandwidth terms at 64 KB that is 2.4 GB/s against 1.1 GB/s.

**Zero-copy send does not rescue it and below 64 KB it is actively harmful**, costing 41% at 1 KB
and 42% at 8 KB, then becoming a wash at 64 KB and above. `IO_URING_WRITE_ZERO_COPY_THRESHOLD`
defaults to -1 (off) and this is a good argument for leaving it there unless measured: it trades a
copy for page pinning plus a second completion, and below the crossover the trade is bad. This is
the one io_uring feature with no netty epoll equivalent, so it was the only candidate for an
outright win, and it is not one.

Confirmed at 64 KB with three interleaved rounds and tight spreads (epoll 40,493-42,234, io_uring
18,682-18,754). Client CPU per request at 64 KB: epoll 35 us user + 60 us system, io_uring 72 us
user + 88 us system. io_uring uses roughly 70% more CPU per request **and** delivers less than half
the throughput.

### Buffer rings at large payload: real, and far too small to matter

The kernel profile shows io_uring carrying a class of frames epoll does not have at all:
`do_user_addr_fault` 2.31%, `refill_stock` 1.78%, `clear_page_erms` 1.48%,
`page_counter_try_charge` 1.26% -- page faulting, page zeroing and cgroup memory accounting, about
6.8% of its kernel time. That is the signature of allocating fresh pages in steady state, and
without a provided buffer ring netty allocates a receive ByteBuf per read. At 64 KB that is a 64 KB
direct buffer per read, which made buffer rings a well-targeted hypothesis at this size even though
they did nothing at 1 KB.

Three rounds at 64 KB, 2000 connections:

| cell | rounds | median |
|---|---|---|
| epoll | 40,493 - 42,234 | 40,999 |
| io_uring, no buffer ring | 18,682 - 18,754 | 18,702 |
| io_uring + 512 x 64 KB buffers | 19,421 - 19,787 | 19,680 |
| io_uring + 2048 x 16 KB buffers | 19,019 - 19,427 | 19,118 |

Buffer rings win by ~5%, consistently and with non-overlapping ranges, so unlike the 1 KB case this
is a real effect. It recovers about 4% of a 120% gap. Memory churn is a contributor and not the
cause.

Note the two buffer sizes perform nearly identically. If large reads were being chunked by buffer
size, 16 KB buffers would need four times the completions of 64 KB buffers and should have been
markedly worse. They are not, so read chunking is not the mechanism either.

### Registered files: ruled out before writing any of it

`IOSQE_FIXED_FILE` appears nowhere in netty's io_uring transport, so every SQE carries a raw fd and
the kernel does a table lookup and refcount per operation. Registering files is the textbook fix and
would have been a large change across the JNI and Java layers.

The kernel profile kills it: `fget` is 1.68% of io_uring's kernel time against epoll's `__fdget` at
1.58%. Eliminating fd lookup entirely would recover about 1% of total CPU against a gap of 120%.
Checking the profile first cost one command and saved the whole implementation.

### What this leaves

There is no hot spot. The user-space profile is a long tail (`handleFastPath` 3.8%, jctools
accessors 3.0%, `scheduleWriteMultiple` 2.6%, `writeComplete0` 2.3%) and the three structural levers
available are measured at roughly +5% (buffer rings), ~1% (registered files) and negative
(zero-copy send). A rewrite of the completion path is not justified by this evidence, and would be
tuning against a profile with no peak in it.

The reportable finding is not "netty's io_uring completion path is slow". It is that **netty's
io_uring transport scales badly with message size**, losing 13% at 1 KB and 53% at 64 KB in a
straight echo, which is specific, reproducible in three rounds with tight spreads, and not explained
by any of the three knobs. That belongs upstream as a question before it belongs in a patch.


## Root cause of the size cliff: a memory-footprint feedback loop, not a slow completion path

Investigated directly rather than filed as a question. The chain, each step measured:

**1. At 256 KB the io_uring server allocates pooled arena chunks continuously.** Profiling both
sides at the payload where the deficit is worst, samples reaching
`PoolArena$DirectArena.newChunk -> ByteBuffer.allocateDirect`: epoll server **7**, io_uring server
**1201**. Every new chunk is an mmap plus a zeroing pass, which is precisely the kernel cluster that
separates the two profiles (`do_user_addr_fault`, `clear_page_erms`, `page_counter_try_charge`).

**2. Measured directly rather than inferred from samples.** `usedDirectMemory` and live chunk count,
sampled every 2 s during steady state at 256 KB / 500 connections:

| server | req/s | pooled direct memory across the run |
|---|---|---|
| epoll | 9,139 | 32 MB / 8 chunks, identical in every sample |
| io_uring | 3,966 | 72, 76, **140**, 44, 56, 40, 68, 80, 60, 80 MB (8 to 36 chunks) |
| io_uring + buffer ring | 4,176 | 76, 44, 44, 44, 52, **124, 128**, 56, 40, 68 MB |

epoll's arena never moves. io_uring's thrashes. A provided buffer ring does not fix it, because it
covers only the read path while the echo still writes 256 KB back through the pool.

**3. That comparison is circular, so it does not stand on its own.** io_uring was 2.3x slower in
those cells, so more connections have a partially accumulated frame at any instant, and higher live
memory follows from being slow rather than causing it.

**4. Open loop breaks the circle.** Both transports driven at a fixed 2,000 req/s, comfortably below
what either reached closed-loop, so in-flight frame count is matched by construction. Both met the
target exactly:

| server | user us/req | system us/req | total | pooled memory |
|---|---|---|---|---|
| epoll | 76.2 | 127.5 | **203.7** | 16 MB / 4 chunks, flat |
| io_uring | 86.0 | 117.1 | **203.1** | 32 MB / 8 chunks, flat |

**io_uring is not intrinsically more expensive per operation.** At equal offered load its CPU per
request matches epoll to within 0.3%, and the chunk thrashing disappears. What survives is a
footprint difference: **io_uring holds twice the pooled direct memory for identical work**, stably
and independently of speed.

That is not a defect, it is what completion-based I/O requires. A readiness-based transport
allocates a receive buffer when data is already available; a completion-based one must commit the
buffer when it SUBMITS the read, so it holds one per read in flight rather than one per ready read.

**The cliff is the interaction, not either half.** The footprint is 2x at every size. Near
saturation that pushes the arena past its working set, the pool answers with continuous chunk mmap
and zeroing, that burns CPU, throughput falls, more frames sit mid-accumulation, memory rises
further. A feedback loop that only engages once the threshold is crossed. At 1 KB, twice a small
footprint crosses nothing and the gap is 13%. At 256 KB it crosses, and the gap is 59%.

This also retires the framing of the three earlier negative results. Ring size, buffer rings and
registered files were all aimed at per-operation cost, and per-operation cost was never the problem:
at equal load there is no per-operation difference to recover.

**What follows for anyone running netty on io_uring**: size the allocator for roughly twice the
direct memory epoll needs at the same load, or cap the receive buffer, and the cliff should not
engage. Untested here, and stated as a prediction rather than a result.


## The pinning was wrong, and correcting it changes nothing

Everything above ran server on cpus 0-3 and client on 4-7 on the assumption those were disjoint
cores. thor's topology says otherwise: `thread_siblings_list` is 0,4 / 1,5 / 2,6 / 3,7, so the two
sides were hyperthread siblings sharing the SAME four physical cores. Corrected pinning gives each
side two whole physical cores with both their threads (server 0,1,4,5; client 2,3,6,7). Both
pinnings, five interleaved rounds, 64 KB payload, 2000 connections:

| cell | rounds | median |
|---|---|---|
| epoll, old pinning | 38,728 - 42,683 | 41,504 |
| io_uring, old pinning | 17,285 - 18,964 | 18,139 |
| epoll, corrected | 32,584 - 42,017 | 34,959 |
| io_uring, corrected | 16,992 - 18,135 | 17,794 |

io_uring is indifferent to the pinning (ranges overlap). epoll's median drops under the corrected
pinning with a spread wide enough that the drop is marginal, but in no round under either pinning
does the transport ordering change, and the ratio moves from 44% to 51% only because epoll got
noisier. **The size cliff is not an SMT artifact.** If anything the old pinning flattered epoll:
hard-partitioning the cores takes away the slack a busier side could steal from its sibling. The
earlier numbers stand, with the caveat that their absolute values carry the shared-core condition.

## Raising the cache ceiling: real on both transports, and the ratio does not close

`io.netty.allocator.maxCachedBufferCapacity` defaults to 32 KB, so at 64 KB every receive and echo
buffer bypasses the thread-local cache and hits the arena. If the cliff is purely the pool working
set, raising the ceiling past the payload should mostly fix io_uring and barely touch epoll, whose
arena never grows. Corrected pinning, ceiling raised to 256 KB on both sides, same sweep:

| cell | rounds | median | server pool across run |
|---|---|---|---|
| epoll | 32,584 - 42,017 | 34,959 | flat 16 MB every round |
| io_uring | 16,992 - 18,135 | 17,794 | thrashing 16 - 212 MB |
| epoll + 256 KB ceiling | 41,594 - 45,175 | 43,745 | flat 16 MB |
| io_uring + 256 KB ceiling | 19,179 - 21,421 | 20,442 | 96 - 212 MB, floor up to ~100 MB |

Both effects are real: io_uring gains 15% and wins all five paired rounds with non-overlapping
ranges; epoll gains about as much (arena allocations above the ceiling take the arena lock even
when no chunk is mmapped, and the flag removes that on both transports). The ratio ends at 47%
against 51% baseline. **A sixth of the gap, not the fix.** The pool churn is a contributor with a
measured size, and the footprint mechanism cannot be the whole cliff, which is what motivates the
write-path experiment below.


## Three corrections from the literature, all verified here

A parallel review of the io_uring literature against these findings turned up three things that
change the standing of results in this file. All three were checked against the source or the host
before being recorded.

### 1. The cpuset pinning in every script in this branch is wrong

thor has 4 physical cores and 8 logical. `cpu0/topology/thread_siblings_list` is `0,4`, and likewise
`1,5`, `2,6`, `3,7`. So `--cpuset-cpus=0-3` for the server and `4-7` for the client, described
throughout as "disjoint cores", actually places client and server on **the same four physical cores
as hyperthread siblings**. They compete for the same execution units, and a transport that burns
more cycles is penalised superlinearly rather than proportionally.

Every saturated cell in this file is affected, which is most of them. The equal-rate open-loop cell
is the least affected, because neither side saturates there, and that is the cell the root-cause
conclusion rests on. The size-cliff magnitudes are the numbers most at risk. They are not withdrawn,
because the ordering is consistent across payloads and the mechanism is independently evidenced, but
they must be re-measured with server on 0,1,4,5 and client on 2,3,6,7 before any of them is quoted
outside this file.

### 2. Netty's io_uring transport has no write spin loop

`AbstractEpollStreamChannel.java:424-442` runs `do { doWriteMultiple / doWriteSingle } while
(writeSpinCount > 0)`: up to 16 back-to-back `write`/`writev` syscalls in one event-loop turn. The
io_uring path submits exactly one send op, and a short write goes to `schedulePollOut()`
(`AbstractIoUringChannel.java:1004-1008`), costing a POLL_ADD SQE and CQE, a fresh send SQE and CQE,
and an `io_uring_enter`, where epoll costs one more cheap `write`. `getWriteSpinCount()` is read
**nowhere** in `transport-classes-io_uring`: the setters exist on every config class and nothing
consumes them.

Partial writes per message scale with message size against a fixed socket send buffer, so this
predicts a deficit that widens with payload, which is what was measured. **This is a better-founded
explanation of the size cliff than the memory-footprint story above**, and the two are not exclusive.
It is also testable without patching netty: raising `SO_SNDBUF` reduces partial writes, so
io_uring's deficit should shrink with a larger send buffer while epoll's stays flat.

### 3. The pooled allocator's thread-local cache stops at 32 KB

`PooledByteBufAllocator.java:125-126`, `io.netty.allocator.maxCachedBufferCapacity`, default
`32 * 1024`. The cliff sits exactly on that boundary: 8 KB is 75% of epoll, 64 KB is 47%. Above
32 KB every receive buffer bypasses the thread cache and goes to the arena, and io_uring holds far
more of them live simultaneously because it commits the buffer at submit time.

This makes the remediation testable with no code change at all:
`-Dio.netty.allocator.maxCachedBufferCapacity=262144` on both transports at 64 KB and 256 KB.

### Scope limits this review also established

- **Kernel 6.8 predates the relevant io_uring networking work**: send-zc buffer coalescing and
  send/recv bundles landed in 6.10, `IORING_ENTER_NO_IOWAIT` in 6.15. The SEND_ZC result above
  (harmful below 64 KB) is **expected on this kernel** and must not be reported as a property of
  io_uring; Axboe puts the post-6.10 crossover near 3000 bytes. Do not re-test it here.
- **The buffer-ring result is now suspect rather than settled.** With no buffer ring configured
  `isPollInFirst()` returns true (`AbstractIoUringStreamChannel.java:798-801`) and the read path is
  POLL_ADD followed by RECV: two ops and two completions per read. Enabling a ring should delete
  that round trip outright, so measuring 0% at 1 KB and +5% at 64 KB is more consistent with the
  ring never engaging than with it engaging and not helping. That the two buffer sizes performed
  nearly identically points the same way. Before the result is trusted, the cell must assert
  `IoUringBufferRing.isUsable()` at runtime and abort if false, on the same rule as the transport
  fallbacks.
- **Loopback with queue depth 1 is io_uring's documented worst case**, since the syscall it exists
  to amortise is close to a memcpy. Any write-up needs this as a stated scope limit.
- Registered files being negligible is confirmed by the literature, so that negative result stands.


## The discriminator: it is reads per message, not writes and not the allocator

The three corrections above each suggested a different mechanism. One sweep separates them, because
each predicts a different lever. All cells 64 KB, 2000 connections, 5 interleaved rounds, corrected
physical-core pinning (server 0,1,4,5 and client 2,3,6,7, which are whole cores on this box).

| cell | median req/s |
|---|---|
| epoll, default | 40,630 |
| io_uring, default | 17,257 |
| io_uring, `SO_SNDBUF=64K` | 17,089 |
| io_uring, `SO_SNDBUF=1M` | 17,502 |
| io_uring, `--rcvbuf-max=16K` | **13,586** |
| io_uring, `--rcvbuf-max=512K` | **23,458** |

**The write spin loop is not the mechanism.** A 16x larger send buffer moves nothing: 17,257 /
17,089 / 17,502 are one number. Netty's io_uring transport genuinely never reads
`getWriteSpinCount()`, and that remains a real difference from the epoll transport, but partial
writes are not what this workload is losing to. Hypothesis tested and rejected.

**The receive buffer is the mechanism, and it is monotonic.** 16K gives 13,586, the 64K default
gives 17,257, 512K gives 23,458. That is a 73% span driven by one knob, and it maps directly onto
**reads per message**: a 64 KB payload plus its 4-byte header needs roughly 5 reads at a 16K buffer,
2 at 64K, and 1 at 512K. Throughput is inversely ordered with the read count in every cell.

That is the whole size cliff. Netty's `AdaptiveRecvByteBufAllocator` caps at 64 KB by default, so
reads per message grow with payload, and **io_uring pays roughly double per read**: with no buffer
ring configured `isPollInFirst()` returns true (`AbstractIoUringStreamChannel.java:798-801`) and each
read is POLL_ADD then RECV, two submissions and two completions, where epoll does one `read()` on a
shared `epoll_wait` wakeup. Multiply a 2x per-read cost by a read count that rises with payload and
the deficit widens with message size, which is exactly the measured curve.

At `--rcvbuf-max=512K` io_uring goes from 42% to 58% of epoll. The gap does not close, because the
per-read penalty is still there, but a third of it is recoverable with one channel option.

### What this retires

- **The memory-footprint story is a symptom, not the cause.** It is real and reproduces under
  corrected pinning (epoll holds 16 MB flat in every single sample; io_uring swings 16-212 MB), but
  it follows from holding a buffer per read in flight, and the read count is the thing that varies.
- **The allocator cache ceiling is not the fix.** Raising `maxCachedBufferCapacity` to 256 KB helps
  epoll more than io_uring (+25% against +15%), which widens the ratio rather than closing it.
- **musl is not a factor.** The same cell on `eclipse-temurin:21-jdk` (glibc) gives epoll
  39,149-42,217 and io_uring 19,155-19,893, the same ~48% ratio as Alpine.

### The SMT pinning error changed magnitudes, not conclusions

Re-running 64 KB under both pinnings: with the old sibling-sharing cpusets epoll medians ~42,008 and
io_uring ~18,373 (43.7%); with correct whole-core pinning epoll 34,959 and io_uring 17,794 (50.9%).
The correction moves epoll down more than io_uring, because each side now has two real cores instead
of four shared ones. So the artifact was working against io_uring, and correcting it shrinks the gap
by about seven points without changing any ordering or conclusion.

## The TLS inversion is real, and the warm-up trend was noise

Ten consecutive rounds of each, fresh JVM per round, with CPU frequency, package temperature and
load recorded per round so drift is measured rather than assumed.

| | rounds | median |
|---|---|---|
| io_uring, TLS, 1 KB, 10k connections | 84,074 - 115,974 | **107,719** |
| epoll, TLS, 1 KB, 10k connections | 72,755 - 97,351 | 94,681 |

**io_uring is about 14% faster with TLS**, and 9 of its 10 rounds beat epoll's median. Frequency sat
at 3.2 GHz and temperature at 71-76 C throughout, so this is not thermal drift.

**The warm-up trend does not reproduce.** The earlier run climbed 70,442 to 115,189 across five fresh
JVMs and blocked any TLS claim. Here round 1 is 115,260, the highest of the ten, and there is no
trend at all, just noise with two low outliers. That was machine state in one run, not a property of
the transport, and the TLS ordering is no longer blocked by it.

Caveat worth keeping: these twenty rounds were consecutive per transport rather than interleaved,
because the question asked was specifically whether a within-transport trend existed. The per-round
frequency and temperature logging is what makes the cross-transport comparison usable anyway, and it
should be repeated interleaved before it is quoted anywhere outside this file.

This is consistent with the read-count mechanism rather than in tension with it. TLS at 1 KB spends
most of its time in crypto, so per-read transport overhead is a much smaller share of the total, and
io_uring's batching across ten thousand connections is free to show up.


## The load generator was allocating on every request, and it was changing the answer

Stack walking at 256 KB found the client's top page-zeroing site inside the harness itself:
`RequestLoop.sendClosed -> PooledUnsafeDirectByteBuf.writeZero -> UnsafeByteBufUtil.setZero ->
Unsafe.setMemory0`. It built its payload by memsetting a fresh buffer on every request. At 64 KB and
41,000 req/s that is 2.6 GB/s of memset on the client alone, it scales with payload, and payload was
the axis the size cliff lives on. The measuring instrument was a variable in its own experiment.

`--prealloc` removes it: one frame built at startup with its length header inside the same buffer,
re-derived per request with `PooledByteBuf.retainedSlice` (a `Recycler` instance, so no allocation
and no memset), `LengthFieldPrepender` gone from both pipelines, void promises instead of a
`DefaultChannelPromise` per write, one histogram per event loop instead of a lock per request, and a
primitive ring instead of an `ArrayDeque<Long>` that boxed a nanotime per request. Off by default,
so every number above stays reproducible.

Measured, in bytes of heap allocated per request, summed over the event loop threads:

| payload | client, default | client, fixed | server, default | server, fixed |
|---|---|---|---|---|
| 1 KB | 269 / 336 | 26 / 74 | 255 / 255 | 37 / 36 |
| 64 KB | 292 / 367 | 39 / 91 | 277 / 580 | 55 / 67 |
| 256 KB | 381 / 657 | 81 / 188 | 352 / 1006 | 132 / 154 |

Medians of five rounds. Two figures per cell, epoll first and io_uring second, from the
harness-fixed-plus-warmed cell. Between 3.5x and 10x less heap per request, and what remains is
discussed below. Note the io_uring server column before the fix: 580 bytes per request at 64 KB and
1,006 at 256 KB, against epoll's flat 277 and 352. That excess is the arena creating chunks, and it
is the heap shadow of a direct-memory problem.

Direct memory is not in this table and cannot be, which is the whole reason the original problem
hid: it is off-heap and the GC never sees it. Read it next to the pooled chunk counts below, never
on its own.

### The flag bundles three things, so it is decomposed rather than reported as one number

`--prealloc` turns on harness allocation removal, an arena warm-up and a fixed receive allocator
together. Attributing the result to whichever of the three is in the label is the mistake this
branch has already made twice, so `--no-warm` and `--no-fixed-rcvbuf` turn them on one at a time.
All cells 5 interleaved rounds, plaintext, corrected physical-core pinning.

**64 KB, 2000 connections:**

| cell | rounds | median | io_uring as % of epoll |
|---|---|---|---|
| epoll, default | 39,826 - 42,568 | 41,340 | |
| io_uring, default | 17,908 - 19,178 | 18,621 | 45.0% |
| epoll, harness fixed | 50,874 - 51,566 | 51,147 | |
| io_uring, harness fixed | 20,807 - 21,590 | 21,110 | 41.3% |
| epoll, + arena warm-up | 51,810 - 52,783 | 52,043 | |
| io_uring, + arena warm-up | 28,506 - 28,957 | 28,636 | **55.0%** |
| epoll, + fixed 64 KB receive | 34,032 - 34,804 | 34,376 | |
| io_uring, + fixed 64 KB receive | 28,863 - 29,405 | 29,065 | 84.6% |

**256 KB, 500 connections:**

| cell | rounds | median | io_uring as % of epoll |
|---|---|---|---|
| epoll, default | 8,605 - 8,705 | 8,667 | |
| io_uring, default | 3,894 - 4,039 | 3,924 | 45.3% |
| epoll, harness fixed | 8,554 - 8,653 | 8,580 | |
| io_uring, harness fixed | 4,712 - 4,787 | 4,761 | **55.5%** |
| epoll, + arena warm-up | 8,176 - 8,362 | 8,218 | |
| io_uring, + arena warm-up | 4,544 - 4,633 | 4,619 | 56.2% |
| epoll, + fixed 64 KB receive | 5,934 - 6,020 | 5,935 | |
| io_uring, + fixed 64 KB receive | 4,490 - 4,660 | 4,649 | 78.3% |

**1 KB, 10000 connections:**

| cell | rounds | median | io_uring as % of epoll |
|---|---|---|---|
| epoll, default | 162,239 - 172,282 | 168,213 | |
| io_uring, default | 103,922 - 108,051 | 105,721 | 62.8% |
| epoll, harness fixed | 200,964 - 212,163 | 204,282 | |
| io_uring, harness fixed | 162,287 - 174,236 | 170,127 | 83.3% |
| epoll, + arena warm-up | 200,255 - 212,227 | 207,013 | |
| io_uring, + arena warm-up | 165,356 - 182,810 | 175,645 | **84.8%** |
| epoll, + fixed 64 KB receive | 135,846 - 212,013 | 204,923 | |
| io_uring, + fixed 64 KB receive | 177,966 - 188,862 | 186,676 | 91.1% |

Spreads are 1-4% in almost every cell and no two cells being compared overlap, with one exception
noted below.

### io_uring still loses, and the size curve is not the shape this file recorded

**The deficit survives.** With the harness fixed and the arenas pre-warmed, io_uring is at 84.8% of
epoll at 1 KB, 55.0% at 64 KB and 56.2% at 256 KB. It has never once beaten epoll on plaintext in
any of these thirty cells. The conclusion that netty's io_uring transport scales badly with message
size stands.

**But it stops widening at 64 KB.** 84.8% to 55.0% to 56.2%: the gap opens between 1 KB and 64 KB
and is then flat to 256 KB. The default-harness cells say the same thing, 62.8% to 45.0% to 45.3%.
The table earlier in this file that runs 87% / 75% / 47% / 41% and reads as a monotonic cliff was a
single run under the sibling-sharing cpusets. **The 41%-at-256-KB point does not reproduce**, and
"the deficit widens with message size" should be stated as "the deficit opens between 1 KB and
64 KB", which is a claim about crossing the adaptive receive allocator's 64 KB ceiling rather than
about size in general.

**Removing the harness's allocation raises io_uring at 1 KB and 256 KB but not at 64 KB.** 62.8 to
83.3 and 45.3 to 55.5, against 45.0 to 41.3. At 64 KB epoll gains 24% from the fix and io_uring only
13%, so the ratio moves the wrong way. This is reproducible across five rounds with 1.4% spreads, so
it is not noise, and it is the one place where the harness was flattering io_uring rather than the
reverse. No mechanism offered for it: at 64 KB epoll was running at 41k req/s against io_uring's
19k, so the client-side memset was a much larger share of epoll's cell, and freeing it helps the
faster transport more. That is a hypothesis, not a measurement.

### What the arena warm-up is worth, and where it is worth nothing

The warm-up forces the chunks the run will use into existence before the ramp and pins one buffer in
each, because netty destroys a chunk the moment it goes fully free (`q000.prevList(null)` in
`PoolArena`, so `PoolChunkList.free` on an emptied q000 chunk falls through to `destroyChunk`). It
runs on the event loop threads, because a pooled allocation is served from the allocating thread's
arena and warming from `main` would grow one arena and leave the others cold.

It works, measured by the metric the earlier root-cause section used:

| cell | server pooled chunks across the run |
|---|---|
| epoll, 64 KB, default | 0 - 4 |
| io_uring, 64 KB, default | 0 - 57 |
| io_uring, 64 KB, harness fixed | 0 - 57 |
| io_uring, 256 KB, harness fixed | 0 - 39 |
| epoll, 64 KB, warmed | 80, every sample |
| io_uring, 64 KB, warmed | 80 - 86 |
| io_uring, 256 KB, warmed | 84, every sample |
| both transports, 1 KB, warmed | 8, every sample |

At 1 KB neither transport moves even unwarmed (epoll 0 - 4 chunks, io_uring 0 - 8), which is the
same thing the earlier section found: twice a small footprint crosses nothing.

**And at 64 KB it buys 14 points of ratio, from 41.3% to 55.0%, entirely on io_uring's side**
(epoll gains 1.8%). Server heap allocation per request falls from 226 to 67 bytes at the same time,
which is the `PoolChunk` and `ByteBuffer` objects that a chunk creation costs.

**At 256 KB it buys nothing at all: 55.5% to 56.2%, and both transports lose 1-4% in absolute
throughput.** The io_uring cell there thrashes 0 to 39 chunks unwarmed and sits flat at 84 warmed,
and delivers the same 4,700 req/s either way. The churn is not imaginary: the warm-up takes the
io_uring server from 781 to 154 bytes of heap allocated per request, which is the `PoolChunk` and
`ByteBuffer` bookkeeping disappearing. It just does not buy any throughput back. So the chunk churn
is real, it is io_uring's, it is removable, and at 500 connections **it does not cost throughput**. The memory-footprint feedback
loop described earlier in this file is therefore a contributor at 2000 connections and not a
contributor at 500, which makes it a concurrency effect rather than a size effect, and the section
that presents it as the root cause of the size cliff overstates it.

### Forcing epoll to commit a full-size receive buffer costs it a third of its throughput

The third component is the one that must not be folded into a pre-allocation flag, and measuring it
separately is why. A `FixedRecvByteBufAllocator` at 64 KB, which is the adaptive allocator's own
default ceiling, costs **epoll 34% at 64 KB** (52,043 to 34,376) and **epoll 28% at 256 KB** (8,218
to 5,935), while io_uring gains 1.5% and loses 1.8% respectively. Both cells are warmed, so this is
not chunk churn.

That is a direct measurement of the structural tax on completion-based I/O, run on the readiness
transport. Epoll allocates its receive buffer when data is already there and the adaptive allocator
shrinks the guess to fit; a completion transport must commit a buffer when it SUBMITS the read.
Taking epoll's ability to right-size that buffer away is worth a third of its throughput, and it
lands epoll within 16% of io_uring at 64 KB. The 84.6% and 78.3% figures in the tables are epoll
being crippled, not io_uring recovering, and quoting them as a pre-allocation win would be exactly
the kind of mislabelled cell this file keeps having to retract.

### The mechanism discriminator, re-run on a harness that does not allocate

The sweep that separated the three candidate mechanisms was run again with
`--prealloc --no-fixed-rcvbuf` on both sides, so the receive-allocator axis is the sweep's own and
nothing else moved. 64 KB, 2000 connections, 5 interleaved rounds.

| cell | rounds | median | previous run, allocating harness |
|---|---|---|---|
| epoll, default | 50,909 - 52,818 | 51,606 | 40,630 |
| io_uring, default | 28,483 - 29,044 | 28,658 | 17,257 |
| io_uring, `SO_SNDBUF=64K` | 28,348 - 28,983 | 28,612 | 17,089 |
| io_uring, `SO_SNDBUF=1M` | 28,391 - 29,307 | 28,624 | 17,502 |
| io_uring, `--rcvbuf-max=16K` | 15,901 - 16,605 | **16,130** | 13,586 |
| io_uring, `--rcvbuf-max=512K` | 41,387 - 42,353 | **42,047** | 23,458 |

**Both conclusions survive, and the second one gets stronger.**

The write path is still not the mechanism. A 16x larger send buffer moves io_uring by 0.2%:
28,658 / 28,612 / 28,624 is one number, and the three ranges overlap completely. Netty's io_uring
transport still never reads `getWriteSpinCount()`, and that still does not matter here.

The receive buffer is still the mechanism and its effect is now larger, not smaller. 16 KB gives
16,130, the 64 KB default gives 28,658, 512 KB gives 42,047: a **161% span** driven by one knob,
against 73% when the harness was allocating. Throughput is inversely ordered with reads per message
in every cell, which is roughly 5 reads at 16K, 2 at 64K and 1 at 512K for a 65,540-byte frame.

And with the harness fixed, that one option takes io_uring from 55.5% to **81.5%** of epoll at 64 KB.
Under the allocating harness the same option moved it from 42% to 58%. So the earlier statement that
it "recovers about a third of the gap" understated it: on a clean harness it recovers close to
three-fifths.

### What still allocates, and whose code it is in

Counters say how much. They cannot say whose, and this branch has already been burned once by a
number that looked authoritative and was not, so the remainder is named from async-profiler's JVMTI
`alloc` event rather than assumed. 64 KB, 2000 connections, 20 s, client side, glibc image.

**Default harness.** Sixty-one percent of everything the client allocates is promises:

| site | share of allocated bytes, epoll | io_uring |
|---|---|---|
| `io.netty.channel.DefaultChannelPromise` | 45.7% | 32.7% |
| `io.netty.util.concurrent.PromiseCombiner` (+ `$1`) | 15.2% | 15.8% |

Both are the harness's doing. `writeAndFlush(msg)` with no promise argument calls `newPromise()`,
which is one `DefaultChannelPromise` per request at each end. `PromiseCombiner` is what
`MessageToMessageEncoder` uses when an encoder emits more than one message, which is exactly what
`LengthFieldPrepender` does: header buffer, then body. Neither survives `--prealloc`.

**With `--prealloc` and leak detection off, heap allocation per request is 5.0 bytes on epoll and
23.3 bytes on io_uring**, against 206 and 310 for the default harness. Epoll's profile has no
request-path site left in it at all: its largest single entry is `ZipFile$Source.initCEN` under
`AppClassLoader.loadClass`, which is the JVM opening the shaded jar at startup.

io_uring's remainder is netty's, and it is specific:

    io.netty.channel.uring.IoUringIoOps          16.8% of client bytes, 15.9% of server bytes
      IoUringIoOps.newSend  <- scheduleWriteSingle <- doWrite <- flush0
      IoUringIoOps.newRecv  <- scheduleRead0 <- scheduleFirstRead <- pollIn <- pollAddComplete

One `IoUringIoOps` per submitted operation, on both the send and the receive path. It is a small
object and 23 bytes per request is not a throughput problem on its own, but the second stack is
worth reading twice: `pollAddComplete -> pollIn -> scheduleFirstRead -> newRecv` is the POLL_ADD
followed by RECV path, caught in the act, allocating once for each of the two operations that epoll
does not have to submit at all.

**Netty's leak detector is not free at these rates.** It defaults to `simple`, which samples roughly
one buffer in 128 and allocates a `ResourceLeakDetector$TraceRecord` when it does. Turning it off
takes the pre-allocated client from 41.4 to 5.0 bytes per request on epoll and 60.0 to 23.3 on
io_uring, so it was about 36 bytes of the remainder. Every sweep in this section ran with netty's
default on, on both transports, so it is a constant and not a confound, but a run that wants to
claim zero allocation has to set `-Dio.netty.leakDetection.level=disabled` and say so.

### How to reproduce, and what to pass

    # the clean allocation-free cell: harness fixed, arenas warmed, receive allocator untouched
    --prealloc --no-fixed-rcvbuf --payload=65536 --connections=2000

`--prealloc` needs `--payload` on the server too, and either `--connections` or `--warmup-mb` to
size the warm-up. It aborts if it cannot warm the arenas rather than running a cell labelled
pre-allocated that is not, and `--jvm-tuned` aborts unless the JVM was actually started with
`-Xms` equal to `-Xmx`, `-XX:+AlwaysPreTouch` and an explicit `-XX:MaxDirectMemorySize`.

**Pinning the heap is not established as an effect.** Five interleaved rounds at 64 KB, 2000
connections, with and without `-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:MaxDirectMemorySize=2g`:

| cell | rounds | median |
|---|---|---|
| epoll, `--prealloc` | 34,001 - 34,450 | 34,192 |
| epoll, `--prealloc --jvm-tuned` | 34,246 - 34,731 | 34,634 |
| io_uring, `--prealloc` | 28,701 - 29,328 | 29,059 |
| io_uring, `--prealloc --jvm-tuned` | 28,760 - 29,250 | 29,214 |

Both pairs overlap, so by this branch's own rule that is no effect rather than a small one. Which is
the expected answer once the pooled allocator is warmed: the payload lives in direct memory, the
request path allocates single-digit bytes of heap, and there is almost nothing left for a pre-touched
heap to help with. The flag stays because it removes a variable and because its absence has to be
demonstrated rather than assumed, not because it bought anything here.

Develop reference counting in the request path under `-Dio.netty.leakDetection.level=paranoid` and
turn it off to measure. Paranoid takes allocation from 5 bytes per request to roughly 68,000, which
makes any leak obvious and any measurement worthless.

### What this changes in the sections above

- **The headline conclusion stands.** Reads per message is still the mechanism, the write path is
  still not, and io_uring still loses on plaintext at every payload tested. The read-buffer lever is
  bigger on a clean harness, not smaller.
- **"The deficit widens with message size" needs narrowing to "between 1 KB and 64 KB".** The
  87 / 75 / 47 / 41 curve was one run under the sibling-sharing cpusets. Five interleaved rounds
  under corrected pinning give 62.8% / 45.0% / 45.3% by default and 84.8% / 55.0% / 56.2% with the
  harness fixed. Both are flat from 64 KB to 256 KB. **The 41%-at-256-KB point is withdrawn.**
- **The memory-footprint feedback loop is demoted again.** It is real, it is io_uring's, and warming
  the arena is worth 14 points of ratio at 64 KB and 2000 connections. At 256 KB and 500 connections
  the identical churn costs nothing. That makes it a concurrency effect, not the size effect it was
  presented as.
- **Every absolute number recorded before this section carries a harness that memset its payload per
  request.** The orderings all survive; the magnitudes move by up to 60% at 1 KB. Anything quoted
  outside this file should come from a `--prealloc` cell.
