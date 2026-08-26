# Test catalogue

Every test run in this work, what it was asking, and what came back. Companion to `FINDINGS.md`,
which carries the conclusions. This file is the evidence trail.

Confidence tags are the same as in `FINDINGS.md`:

- **[SOLID]** multiple interleaved rounds, spreads recorded, raw output still on the test host
- **[SOLID, RECALLED]** measured carefully, but the numbers reached this document through a
  conversation summary rather than raw output I can still read. Believed correct. Re-run before
  publishing an exact digit.
- **[SINGLE RUN]** one measurement, no spread
- **[UNCERTAIN]** something specific is missing, named each time
- **[WITHDRAWN]** claimed then disproved

Host `thor` throughout: 4 physical cores / 8 logical (SMT), kernel 6.8.0-57-generic, 62 GB, Ubuntu.
Guest `eclipse-temurin:21-jdk-alpine` unless stated. Raw logs live in `/home/fred/tls-matrix/*.log`
on thor, named in each entry.

---

## Part A: TLS handshake matrix (JMH microbench)

Ran netty's own `microbench` shaded jar across images, architectures and tcnative flavours. All of
Part A is **[SOLID, RECALLED]**: measured on an idle host with error bars, but the raw JMH JSON is on
thor and was not re-read while writing this.

**[UNCERTAIN] applies to every score in Part A: the unit is not recorded.** These are JMH
`Mode.AverageTime` handshake benchmarks so lower is better and it is time per operation, but whether
nanoseconds or microseconds is not something I can confirm without re-running one cell. Ratios are
safe; absolute values need the unit re-established before publication.

### A1. Does the released tcnative load on Alpine at all?

Levels `library-load`, `init`, `handshake`, both architectures natively.

| arch | flavour | result |
|---|---|---|
| x86_64 | boringssl-static 2.0.81 | **fails at library-load**, catchable `UnsatisfiedLinkError`, `ld-linux-x86-64.so.2` unresolved in `DT_NEEDED` |
| aarch64 | boringssl-static 2.0.81 | **JVM crash**, SIGSEGV in `JVM_LoadLibrary`, uncatchable. `init_have_lse_atomics` calls `__getauxval` from an `.init_array` constructor during `dlopen` |
| x86_64 | openssl-dynamic 2.0.81 | **loads**, reports OpenSSL 3.5.7, once `apr` and `openssl` are in the image |
| aarch64 | openssl-dynamic | **not testable**, no `linux-aarch_64` classifier published |
| both | patched build | loads and handshakes |

### A2. libc effect by tcnative flavour

Insight mode, x86_64, idle host.

| flavour / provider | glibc | musl | delta |
|---|---|---|---|
| openssl-dynamic, OPENSSL | 990.4 +/- 19.8 | 1111.3 +/- 28.2 | +12% (TLS 1.3: +17 to 22%) |
| boringssl-static, OPENSSL | 804.2 +/- 16.9 | 796.7 +/- 13.9 | none |
| JDK provider (control) | no libc effect | no libc effect | none |

Conclusion: the musl penalty belongs to the dynamic flavour, not to musl. Mechanism (runtime libssl
resolution vs compiled-in crypto) is **inferred, never instrumented**.

### A3. Key exchange group sweep

Everything fixed, only the group varied.

| group | score |
|---|---|
| default | 1383.7 +/- 17.6 |
| X25519MLKEM768 | 1367.3 +/- 12.2 |
| X25519 | 1043.7 +/- 11.7 |
| P-256 | 1000.8 +/- 9.0 |

The default equals the post-quantum hybrid. Driven through `-Dnetty.bench.tls.groups` into
`OpenSslContextOption.GROUPS`.

### A4. TLS 1.2 vs 1.3, with and without the group pinned

| comparison | TLS 1.2 | TLS 1.3 | gap |
|---|---|---|---|
| each side's own default group | 804.2 +/- 16.9 | 1346.3 +/- 11.1 | +67% |
| X25519 pinned both sides | 769.8 +/- 11.8 | 1004.0 +/- 12.2 | +30% |

### A5. What a real cloud endpoint negotiates

`s3.eu-west-1.amazonaws.com`: TLSv1.3 / TLS_AES_128_GCM_SHA256 / **X25519MLKEM768** /
rsa_pss_rsae_sha256. Confirms A3's default is what production actually uses.

### A6. Upstream microbench bugs found and fixed on this branch

Four, all **[SOLID, RECALLED]**, all of which made benchmarks silently unrunnable rather than error:

1. Key material loaded via `getResource().getFile()`, which cannot work inside a jar. No SSL
   benchmark in netty's shaded microbench jar could run at all.
2. SSL contexts built eagerly for every provider, so JDK-provider rows failed wherever tcnative was
   absent.
3. `configureEngine()` hardcoded `PROTOCOL_TLS_V1_2`; TLS 1.3 was not benchmarked on any provider.
4. Handshake driver needed to be status-driven and buffers cleared per invocation, not just a
   parameter added.

---

## Part B: load test, transport comparisons

Standalone `loadtest/` project. Plain TCP echo, length-prefixed frames, `TCP_NODELAY`,
`PooledByteBufAllocator`, `SO_BACKLOG=8192`, `nofile=65536`, `seccomp=unconfined`.

**Pinning note that affects B1 through B7:** those runs used cpusets `0-3` (server) and `4-7`
(client), believed disjoint, actually SMT sibling pairs. Quantified in B9. The artifact worked
against io_uring by about seven percentage points and changed no ordering.

### B1. First inversion run [WITHDRAWN in part]

**[SINGLE RUN]** epoll plaintext 166,219 vs io_uring 125,895; epoll TLS 95,382 vs io_uring 104,256.
One sample each on a busy box. Superseded by B2.

### B2. Interleaved inversion, 5 rounds [SOLID, RECALLED]

10k connections, 10 s, 1 KB. `inversion.log`, `inversion2.log`.

| cell | round spread |
|---|---|
| epoll plaintext | 161,845 - 166,798 |
| io_uring plaintext | 118,002 - 121,729 |
| epoll TLS | 67,460 - 95,527 (42%) |
| io_uring TLS | 83,451 - 117,973 (41%) |

Plaintext ordering robust. TLS ordering **not established** at this point.

### B3. Ring size sweep [SOLID, RECALLED] — negative

4096 / 16384 / 32768 gave 127,590 / 127,014 / 125,817. No effect.

**[WITHDRAWN]** An earlier single run showed 578 req/s against epoll's 168,789 alongside a
"CompletionQueue overflow detected" warning, and I claimed a 292x ring effect. The real cause was two
of my own runs colliding on the same port and cores. The warning was a symptom of contention.

### B4. Instrumented run: GC and CPU split, 5 interleaved rounds [SOLID, RECALLED]

`q3.log`. Added utime/stime, GC and context-switch counters.

- **GC hypothesis falsified.** `gcMs` between 71 and 99 while throughput swung 70k to 116k. The
  slowest TLS round had the lowest GC time.
- Medians, us per request: epoll plaintext 152,227 req/s, client 8.40 user / 15.34 sys, server 5.90 /
  15.49. io_uring plaintext 114,980 req/s, client 13.53 / 20.13, server 6.28 / **12.80**.
- The 12.80 server figure led to a claim later **[WITHDRAWN]** in B6.
- io_uring TLS rounds trended upward across fresh JVMs (70,442 / 82,764 / 111,042 / 115,721 /
  115,189), blocking any TLS claim. Later shown not to reproduce, see B12.

### B5. Open-loop mode, coordinated omission [SOLID, RECALLED]

Closed loop reported p50 57 ms, which was Little's Law and not latency. Added `--rate`, measuring
from due time. Verified: 81,987 req/s at p50 1831 us closed-loop against 19,995 req/s at p50 60 us
open-loop. Output now self-labels `closed-loop:latency-is-queue-depth`.

**[UNCERTAIN]** An open-loop anomaly at small payloads was never explained: p50 around 100 us against
p99 around 1 s with the target rate met.

### B6. Transport crossing, 2x2, 5 interleaved rounds [SOLID]

10k connections, 1 KB. The decisive attribution test, since client and server are separate processes.

| server | client | round spread | median | server sys us/req |
|---|---|---|---|---|
| epoll | epoll | 124,125 - 166,896 | **139,356** | 15.6 |
| io_uring | epoll | 106,844 - 125,922 | 115,252 | **21.5** |
| epoll | io_uring | 103,556 - 128,112 | 112,656 | 13.8 |
| io_uring | io_uring | 108,065 - 120,161 | 114,885 | ~20 |

epoll/epoll won all five rounds. **Withdrew two claims**: that the deficit was client-side, and that
io_uring saved 17% of server kernel time. Held against an epoll client the io_uring server uses
*more* kernel time. Penalties are symmetric and do not add.

### B7. Buffer rings and multishot recv

**At 1 KB, 5 interleaved rounds [SOLID] — no effect.**

| cell | spread | median |
|---|---|---|
| epoll | 137,726 - 166,466 | 159,512 |
| io_uring, no ring | 101,105 - 119,759 | 117,079 |
| io_uring + ring 1024 | 110,861 - 120,091 | 116,356 |
| io_uring + ring 4096 | 107,439 - 124,705 | 115,023 |

**At 64 KB, 3 interleaved rounds [SOLID] — real but tiny +5%.**

| cell | spread | median |
|---|---|---|
| epoll | 40,493 - 42,234 | 40,999 |
| io_uring, no ring | 18,682 - 18,754 | 18,702 |
| io_uring + 512 x 64 KB | 19,421 - 19,787 | 19,680 |
| io_uring + 2048 x 16 KB | 19,019 - 19,427 | 19,118 |

**[UNCERTAIN] Now suspect.** Enabling a ring should delete the POLL_ADD round trip entirely, so +5%
fits "the ring never engaged" better than "engaged and did not help". The two buffer sizes performing
identically points the same way. Needs a runtime `IoUringBufferRing.isUsable()` assertion that aborts
the cell. Also found here: `IoUringBufferRingConfig.builder()` throws unless `batchSize()` is called.

### B8. Payload sweep and zero-copy send [SINGLE RUN per cell]

Old pinning. Connections scaled down as payload rose.

| payload | conns | epoll | io_uring | io_uring + SEND_ZC | io_uring % |
|---|---|---|---|---|---|
| 1 KB | 10,000 | 137,671 | 119,917 | 70,156 | 87% |
| 8 KB | 10,000 | 115,997 | 86,717 | 50,535 | 75% |
| 64 KB | 2,000 | 38,914 | 18,137 | 18,374 | 47% |
| 256 KB | 500 | 9,259 | 3,767 | 3,813 | 41% |

The 64 KB row was reproduced properly later (B7, B9, B10). **The 8 KB and 256 KB rows have no error
bars and were never re-run under corrected pinning.** SEND_ZC harm below 64 KB is expected on kernel
6.8, which predates 6.10 buffer coalescing.

### B9. Pinning artifact and cache-ceiling remediation, 5 interleaved rounds [SOLID]

`pc64.log`, `pc256.log`. 64 KB, 2000 connections. `-c` = `maxCachedBufferCapacity` raised to 256 KB.

| cell | median | server pool range |
|---|---|---|
| epoll, old (SMT) pinning | ~42,008 | 16-16 MB |
| epoll, correct pinning | 34,959 | 16-16 MB |
| epoll, correct + cache | **43,745** | 16-16 MB |
| io_uring, old pinning | ~18,373 | 20-196 MB |
| io_uring, correct pinning | 17,794 | 16-212 MB |
| io_uring, correct + cache | 20,442 | 96-212 MB |

Ratio moves 43.7% (old) to 50.9% (correct). **The cache ceiling is not the fix**: it helps epoll
(+25%) more than io_uring (+15%).

### B10. Mechanism discriminator, 5 interleaved rounds [SOLID] — the decisive test

`mech64.log`. 64 KB, 2000 connections, correct pinning. Each hypothesis predicted a different lever.

| cell | median |
|---|---|
| epoll, default | 40,630 |
| io_uring, default | 17,257 |
| io_uring, `SO_SNDBUF=64K` | 17,089 |
| io_uring, `SO_SNDBUF=1M` | 17,502 |
| io_uring, receive buffer 16K | **13,586** |
| io_uring, receive buffer 512K | **23,458** |

Send buffer: nothing, across 16x. **Write-spin-loop hypothesis rejected.** Receive buffer: 73% span,
monotonic, tracking reads per message (roughly 5 / 2 / 1 for a 64 KB payload). Recovers about a third
of the gap.

### B11. glibc control, 5 rounds [SOLID]

`glibc.log`. Same 64 KB cell on `eclipse-temurin:21-jdk`: epoll 39,149 - 42,217, io_uring 19,155 -
19,893. Same ~48% ratio as Alpine. **musl is not a factor.**

### B12. TLS warm-up and ordering, 10 consecutive rounds each [SOLID]

`tlswarm.log`. Fresh JVM per round, with `freqKHz`, `tempMilliC` and `load1m` logged per round.

| | rounds | median |
|---|---|---|
| io_uring TLS | 84,074 - 115,974 | **107,719** |
| epoll TLS | 72,755 - 97,351 | 94,681 |

io_uring ~14% faster, 9 of 10 rounds above epoll's median. Frequency steady at 3.2 GHz, temperature
71-76 C. **The B4 warm-up trend does not reproduce**: round 1 is the highest of the ten.

**[UNCERTAIN]** Consecutive per transport, not interleaved, because the question was about a
within-transport trend. Repeat interleaved before publishing.

### B13. Equal-rate open loop, 256 KB [SOLID] — cause vs effect

Both driven at a fixed 2,000 req/s, below either's capacity. Both met target.

| server | user us/req | sys us/req | total | pooled memory |
|---|---|---|---|---|
| epoll | 76.2 | 127.5 | **203.7** | 16 MB / 4 chunks, flat |
| io_uring | 86.0 | 117.1 | **203.1** | 32 MB / 8 chunks, flat |

**io_uring is not intrinsically more expensive per operation**, 0.3% apart. What survives is a stable
2x memory footprint. This is the cell the memory conclusion rests on, and it is also the cell least
affected by the pinning error since neither side saturates.

### B14. Pooled memory under saturation, 256 KB [SOLID]

| server | req/s | pooled direct memory, sampled every 2 s |
|---|---|---|
| epoll | 9,139 | 32 MB / 8 chunks in every sample |
| io_uring | 3,966 | 72, 76, **140**, 44, 56, 40, 68, 80, 60, 80 MB (8 to 36 chunks) |
| io_uring + buffer ring | 4,176 | 76, 44, 44, 44, 52, **124, 128**, 56, 40, 68 MB |

Reduced by B10 to a symptom rather than the cause.

---

## Part C: profiling

### C1. ctimer profile at 1 KB, client only [SOLID]

epoll: 80,246 samples, 65.6% self time in `ld-musl-x86_64.so.1` (libc syscall stubs). io_uring:
33,398 samples, no dominant frame. Long tail: `syscall` 15.5%, `handleFastPath` 3.5%,
`UnsafeRefArrayAccess.soRefElement` 2.3%, `scheduleWriteMultiple` 2.2%, `writeComplete0` 2.2%.
Context switches: io_uring 1,694 vs epoll 4,293, so batching works while CPU per request is higher.

### C2. Kernel profile at 1 KB [SOLID]

Enabled by `--cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG` plus `seccomp=unconfined`, with
no host sysctl change despite `perf_event_paranoid=4` and `kptr_restrict=1`.

Frames present in io_uring and absent from epoll's top set: `do_user_addr_fault` 2.31%,
`refill_stock` 1.78%, `clear_page_erms` 1.48%, `page_counter_try_charge` 1.26%. `fget` 1.68% against
epoll's `__fdget` 1.58%, which **ruled out registered files** before any JNI was written.

### C3. Sampler accounting check [SOLID] — an instrument caveat

| | system time share of CPU | share of samples on kernel frames |
|---|---|---|
| epoll | 67.9% | 65.8% |
| io_uring | 66.5% | **18.8%** |

epoll accounts for itself; io_uring's kernel time is 3.5x under-reported at 1 KB, ~30% at 256 KB.

**Falsified**: the `io_wq` explanation. A thread census during steady state found no `iou-wrk-*`
threads on either side, so nothing is punted and operations complete inline.

**[UNCERTAIN] Cause not established.** Untested candidates: perf sample throttling, samples inside
`io_uring_enter` with no Java frame to join to, NET_RX softirq charged to the current task with a
kernel-only stack.

### C4. Profile at 256 KB, both sides [SOLID]

Both CPU-saturated at ~78 core-seconds, so equal CPU and half the throughput. io_uring 968 us/req
against epoll 468.

Per request (absolute samples divided by requests, since throughputs differ 2.16x):

| frame | epoll | io_uring | ratio |
|---|---|---|---|
| `jlong_disjoint_arraycopy` | 0.121 | 0.214 | 1.77x |
| `Copy::fill_to_memory_atomic` | 0.023 | 0.054 | 2.32x |
| `rep_movs_alternative` (kernel copy) | 0.078 | 0.066 | 0.85x |

Stack walking split this in two: the client-side fill is the **load generator's own payload
construction** (`RequestLoop.sendClosed -> writeZero`), identical work in both. The server-side one is
netty: `DirectArena.newChunk -> ByteBuffer.allocateDirect`, **7 samples on epoll against 1,201 on
io_uring**. Raw stacks in `stack64.log` and `stack256.log` on thor.

**[UNCERTAIN]** `stack64.log` and `stack256.log` were produced by the background agent and have not
been read. They may contain more than C4 quotes.

---

## Part D: what exists, and what is still open

### Scripts, committed under `loadtest/scripts/`

`thor-pincache.sh` (B9), `thor-mech.sh` (B10), `thor-tlswarm.sh` (B12). Earlier ad hoc scripts live
only in the job tmp directory and on thor.

### Harness options added during the work

`--rate` (open loop), `--ring-size`, `--buffer-ring`, `--buffer-ring-size`, `--zc-threshold`,
`--sndbuf`, `--rcvbuf-max`. Server reports `SERVERCPU` every 2 s with CPU, GC, context switches,
`usedDirectMb` and `pooledChunks`.

### Open, in rough priority order

1. **Re-run B8 under corrected pinning with error bars.** The published payload curve rests on single
   runs at 8 KB and 256 KB.
2. **Settle B7.** Assert `IoUringBufferRing.isUsable()` and abort if false, then re-measure.
3. **Repeat B12 interleaved** before quoting the TLS ordering outside this branch.
4. **Re-establish the Part A unit** by re-running one cell, so the absolute handshake numbers become
   publishable.
5. **Repeat the size sweep on kernel 6.10 or newer**, which is where send-zc coalescing and
   send/recv bundles land, before any result is framed as an io_uring property rather than a
   netty-on-6.8 property.
6. **Explain C3.** Or at minimum publish the checking rule without the cause.
7. **The open-loop p99 anomaly from B5.**
8. Microbench payload-size and cert-type axes; `ci-tls-matrix.yml` has never executed.

### Not done, deliberately

Nothing filed upstream. Two netty bugs are written up and waiting on review: the
`IoUringBufferRingConfig.builder()` `batchSize` trap, and multishot recv being inert unless a buffer
ring is configured.
