# Test catalogue

Every measurement run in this work, what it was configured with, what it returned, and how much you
can trust it. Companion to `FINDINGS.md`, which draws conclusions; this file is the evidence.

Confidence tags are the same as in `FINDINGS.md`:

- **[SOLID]** multiple interleaved rounds, spreads recorded, raw output still retrievable
- **[SOLID, RECALLED]** measured carefully, but the numbers reached this document through a
  conversation summary rather than raw output I can still read. Believed correct, re-run before
  publishing an exact digit
- **[SINGLE RUN]** one measurement, no spread
- **[UNCERTAIN]** something specific is missing, stated each time
- **[WITHDRAWN]** claimed then disproved

## Where the raw data lives

**On `thor`** (reachable as `thor.mf`), under `/home/fred/tls-matrix/`:

| log | what | still present |
|---|---|---|
| `pc64.log` | pinning x cache-ceiling sweep, 64 KB | yes |
| `pc256.log` | same at 256 KB | yes, **unread** |
| `mech64.log` | SO_SNDBUF vs receive-buffer discriminator | yes |
| `tlswarm.log` | ten consecutive TLS rounds per transport | yes |
| `glibc.log` | glibc control at 64 KB | yes |
| `stack64.log`, `stack256.log` | profile stack extracts | yes, **unread** |
| `inversion.log`, `inversion2.log`, `q3.log` | early interleaved transport runs | yes, not re-read since compaction |
| `load.log` .. `load4.log`, `reactor.log` | early load test runs | yes, not re-read |
| `insight.log`, `groups.log`, `x86run.log`, `jar-*.log` | TLS matrix / JMH runs | yes, not re-read |
| `kprof/`, `bigprof/`, `prof/` | async-profiler collapsed stacks | yes |

**Important**: several of these logs were produced before a context compaction and I have not
re-opened them. Numbers in this document tagged `[SOLID, RECALLED]` can very likely be recovered
exactly by reading the corresponding log. That is the cheapest way to upgrade a `RECALLED` tag to
`SOLID` before publishing.

**In this branch**: `loadtest/README.md` (the running narrative), `loadtest/scripts/*.sh` (the sweeps
the Fable agent committed), `.github/scripts/tls-matrix/` (the JMH matrix harness).

**Scripts NOT committed**: the earlier ad-hoc sweeps I wrote into a scratch directory
(`thor-kprof.sh`, `thor-iowq.sh`, `thor-bufring.sh`, `thor-cross.sh`, `thor-payload.sh`,
`thor-bigbuf.sh`, `thor-pool.sh`, `thor-equal.sh`, `thor-big-prof.sh`). Copies exist on thor under
`/home/fred/tls-matrix/`. **These should be committed** if the work is to be reproducible in ten
years; a scratch directory tied to a job id is not durable.

---

# Part A: TLS handshake matrix (JMH, netty microbench)

All pre-compaction. Raw JMH JSON should still exist on thor.

## A1. Baseline: does netty's shaded microbench jar run at all on Alpine

**[SOLID, RECALLED]** Result: **no**, not until fixed. The SSL benchmarks could not initialise
because key material was resolved with `getResource().getFile()`, which fails inside a jar. Four
distinct upstream microbench bugs were found and fixed on this branch:

1. resource loading via `getFile()`
2. SSL contexts built eagerly for every provider, so JDK rows could not run where tcnative was absent
3. `AbstractSslEngineBenchmark.configureEngine()` hardcoded `PROTOCOL_TLS_V1_2`, so TLS 1.3 was never
   benchmarked on any provider
4. handshake driver needed to be status-driven, with per-invocation buffer clearing

**[UNCERTAIN]** Exact file/line references are not in front of me; they are in the branch's commit
history for `microbench/src/main/java/io/netty/microbench/handler/ssl/`.

## A2. tcnative 2.0.81 on Alpine, both architectures

**[SOLID, RECALLED]** Configuration: released `netty-tcnative` 2.0.81, `boringssl-static`, Alpine,
x86_64 and aarch64 native (not emulated).

- x86_64: `library-load` failure, catchable `UnsatisfiedLinkError`, `ld-linux-x86-64.so.2` unresolved
  in `DT_NEEDED`
- aarch64: `jvm-crash`, uncatchable SIGSEGV in `JVM_LoadLibrary` via `init_have_lse_atomics` calling
  `__getauxval` from `.init_array` during `dlopen`

## A3. openssl-dynamic as an Alpine workaround

**[SOLID, RECALLED]** Loads on Alpine x86_64 on released 2.0.81, reports OpenSSL 3.5.7, requires
`apr` and `openssl` in the image. No `linux-aarch_64` classifier published, so x86_64 only.

## A4. libc effect on handshake cost, by tcnative flavour

**[SOLID]** Insight mode, x86_64, idle host. Upgraded from RECALLED: raw records recovered and
committed under `benchmark-report/jmh/`.

| flavour / provider | glibc | musl |
|---|---|---|
| openssl-dynamic, OPENSSL | 990.4 +/- 19.8 | 1111.3 +/- 28.2 |
| boringssl-static, OPENSSL | 804.2 +/- 16.9 | 796.7 +/- 13.9 |
| JDK provider | control, no libc effect | control, no libc effect |

TLS 1.3 rows showed +17-22% for openssl-dynamic on musl.

**Unit verified: `us/op`.** Raw JMH records recovered from thor and committed under
`benchmark-report/jmh/`. All four values above match to three decimals, and the JDK control rows
confirm no libc effect (1935.49 glibc against 1925.21 musl).

## A5. Key exchange group sweep

**[SOLID, RECALLED]** Everything fixed, only `-Dnetty.bench.tls.groups` varied, via
`OpenSslContextOption.GROUPS`.

| group | score |
|---|---|
| default | 1383.7 +/- 17.6 |
| X25519MLKEM768 | 1367.3 +/- 12.2 |
| X25519 | 1043.7 +/- 11.7 |
| P-256 | 1000.8 +/- 9.0 |

Verified against `benchmark-report/logs/groups.log`, which carries these to three decimals.

## A6. TLS 1.2 vs TLS 1.3, group controlled and uncontrolled

**[SOLID, RECALLED]**

| comparison | TLS 1.2 | TLS 1.3 | gap |
|---|---|---|---|
| own defaults | 804.2 +/- 16.9 | 1346.3 +/- 11.1 | +67% |
| X25519 pinned both | 769.8 +/- 11.8 | 1004.0 +/- 12.2 | +30% |

## A7. What a real cloud endpoint negotiates

**[SOLID, RECALLED]** `s3.eu-west-1.amazonaws.com`: TLSv1.3, TLS_AES_128_GCM_SHA256,
**X25519MLKEM768**, rsa_pss_rsae_sha256.

**[UNCERTAIN]** Date of the probe is roughly 2026-08-25. Re-run before publishing, since this is
exactly the kind of fact that changes.

## A8. Cross-checks that were run as negative controls

**[SOLID, RECALLED]** Forcing `OPENSSL` on an image with no tcnative must fail the cell rather than
report a number; `SSL.versionString()` cross-checked so a cell labelled BoringSSL really is
BoringSSL. Both behaved correctly.

## A9. Never executed

**[UNCERTAIN]** `.github/workflows/ci-tls-matrix.yml` is committed and **has never run**. It needs a
fork with Actions enabled. Payload-size and certificate-type axes (phase 6 of the plan) were never
started.

---

# Part B: QUIC musl fix

**[SOLID, RECALLED]** Branch `quic-musl-compat` at `50d78dbc88`, 11 files, +1245 lines. Ports the
tcnative #997 approach to `codec-native-quic`:

- `codec-native-quic/src/main/c/musl_compat.c`, 21 weak fallbacks, guarded `#ifdef __linux__` then
  `#ifdef __GLIBC__`, stat shims implemented via raw syscalls (`SYS_newfstatat`) because glibc 2.17's
  `libc_nonshared.a` stubs call `__xstat`, which musl does not have
- `codec-native-quic/pom.xml`: static libstdc++/libgcc link flags, plus a patchelf antrun step bound
  to `process-test-resources` with a fileset and a `resourcecount count="1"` guard
- `.github/scripts/musl-verify/QuicMuslCheck.java`, 309 lines, QUIC client and server in one JVM,
  levels `load` / `init` / `handshake`

Verified from source on both architectures. **Deliberately unpushed, PR never opened.**

Two build bugs found and fixed on the way, both worth an article beat:

- patchelf was initially bound to `process-classes`, but hawtjni 1.18 binds `build` to
  `generate-test-resources`, so the `.so` did not exist yet and the step silently patched nothing
- the hardcoded `.so` path was wrong because hawtjni nests under `META-INF/native/linux64/`

---

# Part C: Load test harness

Standalone Maven project at `loadtest/`, **not** a netty module. `LoadTest.java`, `Transports.java`,
`Tls.java`, `Args.java`, `Counters.java`.

Design decisions that matter for reproducibility:

- **Aborts, never falls back.** Netty defaults to NIO when a native transport is missing; this
  harness throws instead.
- **Two phases reported separately**: ramp (connection establishment and handshakes) and steady.
- **Closed loop by default**, one request in flight per connection, and the output line says so
  (`mode=closed-loop:latency-is-queue-depth`) because p50 in that mode is queue depth.
- **Open loop via `--rate`**, measuring from *due* time to avoid coordinated omission.
- **Counters from procfs and JMX**: `/proc/self/stat` fields 14/15 for user and system time, context
  switches summed over `/proc/self/task/*` (the process file reports the main thread only, which in
  netty does nothing after bind), `GarbageCollectorMXBean` for pauses.
- **Pool metrics**: `usedDirectMemory` and live chunk count on the server line, added late.
- Options added over time: `--ring-size`, `--buffer-ring`, `--buffer-ring-size`, `--zc-threshold`,
  `--sndbuf`, `--rcvbuf-max`.

Standard container flags: `--network=host`, `--security-opt seccomp=unconfined` (docker's default
seccomp blocks `io_uring_setup`), `--ulimit nofile=65536:65536`, `--ulimit memlock=-1` for zero-copy
cells, `SO_BACKLOG=8192`.

---

# Part D: Load test experiments, chronological

## D1. First 10k-connection runs

**[SINGLE RUN]** epoll ahead on plaintext (166,219 vs 125,895), io_uring ahead with TLS (104,256 vs
95,382). One sample each, on a box whose load average looked high. Everything after this was
interleaved because of this run.

## D2. Ring size sweep

**[SOLID, RECALLED]** 4096 / 16384 / 32768 at 10k connections: **127,590 / 127,014 / 125,817**. No
difference.

**[WITHDRAWN]** This sweep retracted a claimed 292x effect. The original observation (578 req/s
against epoll's 168,789, with a "CompletionQueue overflow detected" warning) was caused by two of my
own runs colliding on the same port and cores. Correction committed at `45a06b50bf`.

## D3. Interleaved transport comparison, 5 rounds

**[SOLID, RECALLED]** 10k connections, 10 s, 1 KB.

| cell | round spread | verdict |
|---|---|---|
| epoll plaintext | 161,845 - 166,798 | epoll ~39% faster, robust |
| io_uring plaintext | 118,002 - 121,729 | |
| epoll TLS | 67,460 - 95,527 (42%) | not established at the time |
| io_uring TLS | 83,451 - 117,973 (41%) | |

## D4. Q3 instrumented run: where does the CPU go

**[SOLID, RECALLED]** Medians per request, microseconds:

| | req/s | client utime | client stime | server utime | server stime |
|---|---|---|---|---|---|
| epoll plaintext | 152,227 | 8.40 | 15.34 | 5.90 | 15.49 |
| io_uring plaintext | 114,980 | 13.53 | 20.13 | 6.28 | 12.80 |

This produced two conclusions that were **later withdrawn** (see D9): that the deficit was
client-side, and that io_uring saved 17% of server kernel time.

## D5. GC hypothesis

**[SOLID, RECALLED]** **Falsified.** `gcMs` between 71 and 99 across TLS rounds while throughput swung
70k to 116k. epoll's slowest TLS round (77,030) had its lowest GC (71 ms); its fastest (95,360) had
77 ms. No correlation, and the correlation runs the wrong way if anything.

Also noted: the asymmetry that motivated the hypothesis (plaintext 3% spread vs TLS 42%) did not
reproduce. In that run plaintext spanned 22% and TLS 23%.

## D6. async-profiler `ctimer`, plaintext client

**[SOLID]** 10k connections, 20 s, 1 KB.

- epoll: 80,246 samples, **65.6% self-time in `/lib/ld-musl-x86_64.so.1`** (libc syscall stubs)
- io_uring: 33,398 samples, **no dominant frame**. 15.5% `syscall`, then `handleFastPath` 3.5%,
  `UnsafeRefArrayAccess.soRefElement` 2.3%, `scheduleWriteMultiple` 2.2%, `writeComplete0` 2.2%
- Context switches: io_uring 1,694 voluntary vs epoll 4,293. Batching works, and CPU per request is
  still higher.

**[SOLID] Caveat found by cross-checking**: async-profiler under-sampled io_uring 2.4x (33.4 s of
samples for 79.7 s of CPU; epoll matched at 80.2 vs 78.5). The two profiles are not comparable as
percentages.

## D7. Buffer rings and multishot recv at 1 KB

**[SOLID]** 5 interleaved rounds, 10k connections, 10 s.

| cell | rounds | median |
|---|---|---|
| epoll | 137,726 - 166,466 | 159,512 |
| io_uring, no buffer ring | 101,105 - 119,759 | 117,079 |
| io_uring + ring 1024 | 110,861 - 120,091 | 116,356 |
| io_uring + ring 4096 | 107,439 - 124,705 | 115,023 |

No effect. Discovered here: netty arms `IORING_RECV_MULTISHOT` only inside
`scheduleReadProviderBuffer()`, reached only with a buffer ring configured, and none is configured by
default. Also found `IoUringBufferRingConfig.builder()` throws unless `batchSize()` is set.

## D8. io_wq thread census

**[SOLID]** Thread census by name during steady state, both transports, both sides. **No `iou-wrk-*`
threads at all.** Operations complete inline; nothing is punted to io_wq. This falsified the leading
explanation for the profiler shortfall in D6.

**[UNCERTAIN]** The census script's CPU columns were mislabelled by a one-field offset in
`/proc/<tid>/stat` parsing. The thread *names*, which is what the test was for, are correct. The CPU
figures from that script were never used.

## D9. Cross-transport 2x2

**[SOLID]** 5 interleaved rounds, 10k connections, 10 s, 1 KB.

| server | client | round spread | median | server stime/req |
|---|---|---|---|---|
| epoll | epoll | 124,125 - 166,896 | 139,356 | 15.6 us |
| io_uring | epoll | 106,844 - 125,922 | 115,252 | 21.5 us |
| epoll | io_uring | 103,556 - 128,112 | 112,656 | 13.8 us |
| io_uring | io_uring | 108,065 - 120,161 | 114,885 | ~20 us |

epoll/epoll leads all five rounds individually. **Withdrew two claims from D4.** Also established
that the two penalties do not add, which is the signature of a closed-loop pipeline where the slowest
stage sets the rate.

**[UNCERTAIN]** epoll/epoll drifted upward across rounds (131k, 124k, 139k, 167k, 166k), so the
machine was not steady for the whole run.

## D10. Payload sweep and zero-copy send

**[SINGLE RUN per cell]** Connections scaled down as payload rose. **Old (SMT-sibling) pinning.**

| payload | conns | epoll | io_uring | io_uring + SEND_ZC |
|---|---|---|---|---|
| 1 KB | 10,000 | 137,671 | 119,917 | 70,156 |
| 8 KB | 10,000 | 115,997 | 86,717 | 50,535 |
| 64 KB | 2,000 | 38,914 | 18,137 | 18,374 |
| 256 KB | 500 | 9,259 | 3,767 | 3,813 |

The 64 KB row was later reproduced across many interleaved rounds. **The 8 KB and 256 KB rows were
never re-run** and have no error bars.

## D11. Buffer rings at 64 KB

**[SOLID]** 3 interleaved rounds, 2000 connections.

| cell | rounds | median |
|---|---|---|
| epoll | 40,493 - 42,234 | 40,999 |
| io_uring, no ring | 18,682 - 18,754 | 18,702 |
| io_uring + 512 x 64 KB | 19,421 - 19,787 | 19,680 |
| io_uring + 2048 x 16 KB | 19,019 - 19,427 | 19,118 |

A real, non-overlapping +5%, recovering about 4% of a 120% gap. **[UNCERTAIN]** Now suspect: enabling
a ring should delete the POLL_ADD round trip entirely, so +5% is more consistent with the ring never
engaging. Needs an `isUsable()` assertion that aborts.

## D12. Kernel profiling at 1 KB, with capabilities

**[SOLID]** Technique: `--cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG` plus
`seccomp=unconfined`, `event=cpu`. Kernel frames resolve by name with no host sysctl change.

Frames unique to io_uring: `do_user_addr_fault` 2.31%, `refill_stock` 1.78%, `clear_page_erms` 1.48%,
`page_counter_try_charge` 1.26%. `fget` 1.68% against epoll's `__fdget` 1.58%, which ruled out
registered files.

**[SOLID] Sample accounting**: epoll 65.8% of samples on kernel frames against 67.9% measured system
time (matches); io_uring 18.8% against 66.5% (3.5x shortfall, cause unexplained).

## D13. Profiling at 256 KB, both sides

**[SINGLE RUN]** 500 connections, 20 s. Both transports CPU-saturated at ~78 core-seconds, so a clean
same-CPU comparison: epoll 8,367 req/s at 468 us/req, io_uring 3,877 at 968 us/req.

Per-request sample ratios: `jlong_disjoint_arraycopy` 1.77x, `Copy::fill_to_memory_atomic` 2.32x,
kernel `rep_movs_alternative` 0.85x. io_uring does less kernel copying and more userspace zeroing.

Stack walk found two distinct sources:

- client-side fill is **the load generator's own payload construction** (`RequestLoop.sendClosed ->
  writeZero`), identical work in both, not netty
- server-side is netty: `PoolArena$DirectArena.newChunk -> ByteBuffer.allocateDirect`, **7 samples on
  epoll, 1,201 on io_uring**

**[UNCERTAIN]** `stack64.log` and `stack256.log` on thor contain further stack extracts that were
never read.

## D14. Pooled memory measurement

**[SINGLE RUN per cell]** 256 KB, 500 connections, `usedDirectMemory` and live chunks every 2 s.

| server | req/s | pooled memory across the run |
|---|---|---|
| epoll | 9,139 | 32 MB / 8 chunks, identical every sample |
| io_uring | 3,966 | 72, 76, 140, 44, 56, 40, 68, 80, 60, 80 MB (8-36 chunks) |
| io_uring + buffer ring | 4,176 | 76, 44, 44, 44, 52, 124, 128, 56, 40, 68 MB |

## D15. Equal-rate open loop, the decisive control

**[SINGLE RUN per cell, but the cleanest comparison in the whole branch]** Both driven at a fixed
2,000 req/s, both met target exactly.

| server | user us/req | system us/req | total | pooled |
|---|---|---|---|---|
| epoll | 76.2 | 127.5 | **203.7** | 16 MB / 4 chunks, flat |
| io_uring | 86.0 | 117.1 | **203.1** | 32 MB / 8 chunks, flat |

**io_uring is not intrinsically more expensive per operation** at equal load, and the chunk thrashing
disappears. What survives is a stable 2x memory footprint.

**Worth repeating with rounds and spreads.** This single pair carries a lot of the argument.

## D16. Pinning and cache-ceiling sweep

**[SOLID]** 5 rounds, 64 KB, 2000 connections. `-new` is corrected whole-core pinning (server
0,1,4,5; client 2,3,6,7), `-old` is the SMT-sibling pinning, `-c` raises
`io.netty.allocator.maxCachedBufferCapacity` to 256 KB.

| cell | median | server pool range |
|---|---|---|
| epoll old | ~42,008 | 16-16 MB |
| epoll new | 34,959 | 16-16 MB |
| epoll new + cache | 43,745 | 16-16 MB |
| io_uring old | ~18,373 | 20-196 MB |
| io_uring new | 17,794 | 16-212 MB |
| io_uring new + cache | 20,442 | 96-212 MB |

The SMT artifact was working against io_uring (ratio 43.7% old, 50.9% corrected). The cache ceiling
helps epoll more than io_uring and is **not** the fix.

**[UNCERTAIN]** `pc256.log`, the same sweep at 256 KB, exists on thor and **was never read**.

## D17. Mechanism discriminator

**[SOLID]** 5 interleaved rounds, 64 KB, 2000 connections, corrected pinning. **The single most
important run in this work.**

| cell | median |
|---|---|
| epoll default | 40,630 |
| io_uring default | 17,257 |
| io_uring `SO_SNDBUF=64K` | 17,089 |
| io_uring `SO_SNDBUF=1M` | 17,502 |
| io_uring `--rcvbuf-max=16K` | 13,586 |
| io_uring `--rcvbuf-max=512K` | 23,458 |

Send buffer moves nothing (rejects the write-spin-loop hypothesis). Receive buffer moves throughput
73% monotonically, tracking reads per message.

## D18. glibc control

**[SOLID]** 5 rounds, 64 KB, `eclipse-temurin:21-jdk` instead of Alpine: epoll 39,149 - 42,217,
io_uring 19,155 - 19,893. Same ~48% ratio. **musl is not a factor.**

## D19. TLS warm-up and TLS ordering

**[SOLID for the trend question, UNCERTAIN for the ordering]** Ten consecutive fresh-JVM rounds per
transport, 10k connections, 1 KB, with per-round CPU frequency, package temperature and load average.

| | rounds | median |
|---|---|---|
| io_uring TLS | 84,074 - 115,974 | 107,719 |
| epoll TLS | 72,755 - 97,351 | 94,681 |

**No warm-up trend**: round 1 is the highest io_uring round of the ten. The earlier five-round climb
(70,442 to 115,189) does not reproduce and was machine state.

io_uring ~14% faster, 9 of 10 rounds above epoll's median, frequency stable at 3.2 GHz and temperature
71-76 C. **[UNCERTAIN]** Consecutive per transport, not interleaved, because the question asked was
about a within-transport trend. Repeat interleaved before publishing the ordering.

---

# Open items never completed

- **[UNCERTAIN] Open-loop p99 anomaly at small payloads**: p50 around 100 us against p99 around 1 s
  with the target rate met. Never explained.
- **[UNCERTAIN] The async-profiler shortfall on io_uring**: cause unknown, io_wq falsified.
- `pc256.log`, `stack64.log`, `stack256.log` on thor: produced, never read.
- 8 KB and 256 KB payload rows: never re-run with rounds or corrected pinning.
- `ci-tls-matrix.yml`: committed, never executed.
- Microbench payload-size and certificate-type axes: never started.
- The Medium draft written earlier in this work
  (`~/.claudem/jobs/6c46f506/tmp/medium-draft.md`, roughly 1400 words): **[UNCERTAIN]** that path is a
  job scratch directory and may no longer exist. It should be treated as lost and rewritten from
  `FINDINGS.md`.
- Nothing is pushed anywhere. The netty checkout has only `origin` pointing at upstream netty/netty,
  so there is no fork remote to push to.

# If you want these numbers to survive ten years

The fragile parts, in order of fragility:

1. **The uncommitted scratch scripts.** Copies exist only on thor and in a job scratch directory.
2. **The `[SOLID, RECALLED]` numbers.** Recoverable by reading the logs on thor, which is a cheap
   thing to do once and would upgrade most of Part A.
3. **The JMH unit ambiguity.** One re-run settles it permanently.
4. **thor itself.** Everything here is one machine, reachable over a VPN that dropped mid-session at
   least once. Kernel version, core count and SMT topology are all load-bearing for the io_uring
   results.
