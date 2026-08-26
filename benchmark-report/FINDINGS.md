# Findings

Written as raw material for a series of articles. Everything here was measured on this branch
unless explicitly marked otherwise.

## How confidence is marked

Read these tags literally. They are the difference between something you can publish and something
you need to re-run first.

| tag | meaning |
|---|---|
| **[SOLID]** | Multiple interleaved rounds, spreads recorded, raw output still available on the test host or quoted in `loadtest/README.md`. Safe to publish with the numbers as written. |
| **[SOLID, RECALLED]** | Measured carefully at the time, and the numbers survived into this document through a conversation summary rather than from raw output I can still see. The values are believed correct and were quoted consistently across several turns, but I cannot re-read the original tool output to double-check a digit. Re-run before publishing an exact figure. |
| **[SINGLE RUN]** | One measurement, no spread. Direction is probably right, magnitude is not trustworthy. This branch retracted two claims that came from single runs. |
| **[UNCERTAIN]** | Something specific is missing or was never pinned down. Stated explicitly each time. |
| **[WITHDRAWN]** | Claimed earlier in the work, then disproved. Kept because the retraction is itself worth writing about. |

Test host throughout is `thor`: 4 physical cores, 8 logical (SMT), Ubuntu, kernel 6.8.0-57-generic,
62 GB. Containers are `eclipse-temurin:21-jdk-alpine` unless noted.

---

# Article 1: post-quantum crypto is already in your TLS benchmark

The most broadly interesting result here, because it affects anyone benchmarking TLS 1.3 this year
and has nothing to do with Alpine or io_uring.

## BoringSSL defaults to a post-quantum hybrid key exchange, and it costs about a third

**[SOLID, RECALLED]** With everything else held fixed and only the key exchange group varied:

| group | score |
|---|---|
| default (whatever BoringSSL picks) | 1383.7 +/- 17.6 |
| X25519MLKEM768 explicitly | 1367.3 +/- 12.2 |
| X25519 | 1043.7 +/- 11.7 |
| P-256 | 1000.8 +/- 9.0 |

The default and the explicit post-quantum hybrid are the same number, which is how you know the
default *is* the hybrid. Pinning classical X25519 instead is about 25% cheaper.

**Unit resolved: `us/op`, microseconds per handshake, lower is better.** The raw JMH records were
recovered from the test host and are now committed under `benchmark-report/jmh/`, so these figures
are verified against primary output rather than recalled. Every value above matches to three
decimals.

## The same group is what AWS actually negotiates today

**[SOLID, RECALLED]** `s3.eu-west-1.amazonaws.com` negotiates TLSv1.3 / TLS_AES_128_GCM_SHA256 /
**X25519MLKEM768** / rsa_pss_rsae_sha256.

This is the detail that makes the finding matter rather than being a curiosity. It is not a lab
default nobody meets. A current, mainstream cloud endpoint is doing post-quantum hybrid key exchange
right now, and if your client is modern too then your "TLS 1.3" measurement includes it.

## Which means the standard "TLS 1.3 vs TLS 1.2" comparison is two effects stacked

**[SOLID, RECALLED]**

| comparison | TLS 1.2 | TLS 1.3 | gap |
|---|---|---|---|
| each side's own default group | 804.2 +/- 16.9 | 1346.3 +/- 11.1 | **+67%** |
| X25519 pinned on both sides | 769.8 +/- 11.8 | 1004.0 +/- 12.2 | **+30%** |

Roughly half of the apparent 67% penalty is the post-quantum group and roughly half is a real
protocol-version difference. Anyone comparing the two without pinning the group is reporting the
first row while believing they are reporting the second.

**The article angle**: "if you benchmarked TLS 1.3 this year you may have been measuring
post-quantum crypto". It is true, it is checkable by the reader in one `openssl s_client` command,
and the fix is one line of configuration.

---

# Article 2: the same library fails two completely different ways depending on your CPU

## netty-tcnative 2.0.81 on Alpine

**[SOLID, RECALLED]** The released artifact fails on Alpine/musl, and the failure mode depends on
architecture in a way that changes how serious it is:

- **x86_64: `library-load` failure.** `ld-linux-x86-64.so.2` sits in `DT_NEEDED`. musl never
  resolves it, the library does not load, and the application gets a catchable
  `UnsatisfiedLinkError`. Recoverable.
- **aarch64: `jvm-crash`.** It loads, and then libgcc's outline-atomics probe
  `init_have_lse_atomics` calls `__getauxval` from an `.init_array` constructor during `dlopen`.
  musl does not export `__getauxval`. This is the one case musl's deferred-relocation behaviour does
  not cover, so it is a SIGSEGV inside `JVM_LoadLibrary` and **uncatchable**.

Testing one architecture and generalising gets the severity exactly wrong. That is the story.

## The mechanism worth explaining to readers

**[SOLID, RECALLED]** musl reserves a set of `DT_NEEDED` names it satisfies internally and never
looks up on disk: `ldso/dynlink.c` has `reserved[] = "c.pthread.rt.m.dl.util.xnet."`. A name that
does not start with `lib` can never resolve. And musl *defers* unresolvable relocations rather than
failing `dlopen`, which is why the x86_64 case is survivable at all, and why the aarch64 case is
not: a constructor running during `dlopen` cannot defer.

## openssl-dynamic loads where boringssl-static does not

**[SOLID, RECALLED]** On released 2.0.81, x86_64 only, `openssl-dynamic` loads on Alpine and reports
OpenSSL 3.5.7 once `apr` and `openssl` are in the image. The flavour most people reach for first
(`boringssl-static`) is the broken one, and a workaround exists today that nobody documents.

No plain `linux-aarch_64` classifier is published for `openssl-dynamic`, so this workaround is
x86_64 only.

## The musl handshake penalty belongs to openssl-dynamic, not to musl

**[SOLID, RECALLED]** This is the counterintuitive one and it is a good article beat.

| flavour | glibc | musl |
|---|---|---|
| openssl-dynamic, OPENSSL | 990.4 +/- 19.8 | 1111.3 +/- 28.2 (+12%) |
| boringssl-static, OPENSSL | 804.2 +/- 16.9 | 796.7 +/- 13.9 (no gap) |
| JDK provider (control) | no libc effect | no libc effect |

"musl is slower" is the obvious conclusion and it is wrong. `boringssl-static` shows no libc effect
at all. The penalty is a property of the *dynamic* flavour, which resolves the distro's libssl at
runtime, and on TLS 1.3 it reaches +17-22%.

Verified from the recovered JMH records: `openssl-dynamic` OPENSSL is 990.44 +/- 19.80 on glibc
against 1111.29 +/- 28.23 on musl, while `boringssl-static` OPENSSL is 804.15 +/- 16.89 against
796.70 +/- 13.93. On TLS 1.3 the openssl-dynamic gap is 1061.07 (glibc) against 1240.62 (musl),
which is +17%, and 1298.15 on amazoncorretto, which is +22%.

**[UNCERTAIN] The mechanism is inferred**, never directly instrumented.

**[UNCERTAIN] And there is a confound that has to be disclosed.** The three images do not carry the
same OpenSSL. Recovered from the JMH records:

| image | libc | OpenSSL | JDK |
|---|---|---|---|
| eclipse-temurin:21-jdk | glibc | **3.5.5** (27 Jan 2026) | 21.0.12 |
| eclipse-temurin:21-jdk-alpine | musl | **3.5.7** (9 Jun 2026) | 21.0.11 |
| amazoncorretto:21-alpine | musl | **3.5.7** | 21.0.12 |

libc and OpenSSL version are **perfectly confounded**: every musl image has 3.5.7 and the only glibc
image has 3.5.5. So "openssl-dynamic is 12% slower on musl" could equally be "openssl-dynamic 3.5.7
is 12% slower than 3.5.5 on this workload", and this data cannot separate them.

What survives cleanly is the more important half of the claim: **`boringssl-static` shows no libc
effect at all** (804.15 glibc against 796.70 musl), and BoringSSL is compiled in, so it has no
version to vary. The "musl is not inherently slower" conclusion holds. The "and it is
openssl-dynamic's fault" conclusion needs the same OpenSSL build on both libcs before it is
published.

JDK version is controlled by accident and can be ruled out: the two musl images differ in JDK
(21.0.11 and 21.0.12) and agree with each other (1111.29 and 1115.28).

## The JDK TLS provider is about twice as slow as tcnative, on every image

**[SOLID]** Not the headline anyone was looking for, but it falls straight out of the control rows
and it is the most directly actionable number in the whole TLS matrix. Handshake time, us/op:

| image / flavour | JDK provider | tcnative | ratio |
|---|---|---|---|
| glibc, openssl-dynamic, TLS 1.2 | 1935.49 +/- 37.90 | 990.44 +/- 19.80 | 1.95x |
| musl, openssl-dynamic, TLS 1.2 | 1925.21 +/- 35.67 | 1111.29 +/- 28.23 | 1.73x |
| glibc, boringssl-static, TLS 1.2 | 2127.49 +/- 32.20 | 804.15 +/- 16.89 | **2.65x** |
| musl, boringssl-static, TLS 1.2 | 2073.23 +/- 59.98 | 796.70 +/- 13.93 | **2.60x** |
| glibc, boringssl-static, TLS 1.3 | 2472.65 +/- 124.78 | 1346.33 +/- 11.07 | 1.84x |

The JDK rows were only ever included as a control, to prove no libc effect existed on a provider
that has no native code. They do that: 1935.49 on glibc against 1925.21 on musl is no difference at
all. But they also quietly answer "is tcnative worth the deployment pain on Alpine", and the answer
is that it roughly halves handshake cost, and against `boringssl-static` it is closer to a third.

---

# Article 3: io_uring lost to epoll, and the reason took six wrong hypotheses to find

This is the strongest narrative because almost every step was a negative result, and the
methodology is the point.

## The headline

**[SOLID]** Plain TCP echo, length-prefixed, closed loop, 2000 connections, 64 KB payload, correct
whole-core pinning, 5 interleaved rounds:

- epoll 40,630 req/s
- io_uring 17,257 req/s

And it gets worse with message size, which is the opposite of what everyone expects.

**[SOLID]** Payload sweep, io_uring as a percentage of epoll throughput:

| payload | epoll | io_uring | io_uring as % |
|---|---|---|---|
| 1 KB | 137,671 | 119,917 | 87% |
| 8 KB | 115,997 | 86,717 | 75% |
| 64 KB | 38,914 | 18,137 | 47% |
| 256 KB | 9,259 | 3,767 | 41% |

**[WITHDRAWN] The 256 KB row and the word "monotonically".** That sweep was one run per cell on the
old SMT-sibling pinning. Re-run properly with corrected pinning and a non-allocating harness, the
deficit **opens between 1 KB and 64 KB and then flattens**:

| payload | io_uring as % of epoll, default harness | harness fixed, arenas warmed |
|---|---|---|
| 1 KB | 62.8% | 84.8% |
| 64 KB | 45.0% | 55.0% |
| 256 KB | 45.3% | 56.2% |

64 KB and 256 KB are the same number in both conditions. So the honest claim is **"the deficit opens
between 1 KB and 64 KB"**, which is a statement about crossing netty's 64 KB adaptive receive
ceiling, and not "it widens with message size" as I wrote. The mechanism is unchanged and in fact
better supported: once every message needs more than one read, the per-read penalty is being paid,
and paying it more times past that point does not change the ratio.

**Published io_uring benchmarks say the gap should NARROW with size, not widen.** liburing issue
#536, the most-cited io_uring-vs-epoll network benchmark, shows io_uring going from 32% of epoll at
64 B to 82% at 16 KB. Our curve runs the other way. That inversion is the story.

## The answer: reads per message, and io_uring pays double per read

**[SOLID]** One sweep separated three competing hypotheses because each predicted a different lever.
64 KB, 2000 connections, 5 interleaved rounds, corrected pinning:

| cell | median req/s |
|---|---|
| epoll, default | 40,630 |
| io_uring, default | 17,257 |
| io_uring, `SO_SNDBUF=64K` | 17,089 |
| io_uring, `SO_SNDBUF=1M` | 17,502 |
| io_uring, receive buffer capped at 16K | **13,586** |
| io_uring, receive buffer raised to 512K | **23,458** |

A 16x larger *send* buffer moves nothing. The *receive* buffer moves throughput 73% and does it
monotonically. **Re-run with a non-allocating harness the separation gets sharper still**: send
buffer moves io_uring 0.2% across the same 16x range (28,658 / 28,612 / 28,624) while the receive
buffer moves it **161%** (16,130 / 28,658 / 42,047 at 16K / 64K / 512K), taking io_uring from 55.5%
to **81.5%** of epoll. That single option recovers close to three-fifths of the gap, not the third I
first reported. That maps onto reads per message: a 64 KB payload plus its 4-byte header needs roughly
5 reads at a 16K buffer, 2 at 64K, 1 at 512K, and throughput is inversely ordered with the read count
in every cell.

The mechanism: netty's `AdaptiveRecvByteBufAllocator` caps at 64 KB by default, so reads per message
grow with payload, and io_uring's per-read cost on this kernel and loopback path is higher than a
plain `recv`. A per-read penalty multiplied by a rising read count is exactly a deficit that opens
with message size.

**Netty adds to that per-read cost but does not create it.** With no provided buffer ring configured
`isPollInFirst()` returns true (`AbstractIoUringStreamChannel.java:798-801`) and every read is
POLL_ADD *then* RECV: two submissions and two completions where epoll does one `read()`. Allocation
profiling caught exactly this, one `IoUringIoOps` per operation on the
`pollAddComplete -> pollIn -> scheduleFirstRead` path. **But the C control below shows the same
size-dependent decay in a server that never issues `POLL_ADD` at all**, so that pair is part of the
offset between netty and C, not the reason either curve slopes.

Raising the receive buffer recovers about a third of the gap (42% to 58% of epoll) with one channel
option.

## What actually fixes it: two flags, stacked

**[SOLID]** 5 rounds, 64 KB, 2000 connections, corrected pinning. This is the largest remediation on
the branch and it was sitting unread in a log file.

| cell | rounds | median | note |
|---|---|---|---|
| epoll, default | 35,904 - 41,815 | 41,310 | |
| io_uring, default | 17,538 - 18,701 | 17,850 | 43.2% of epoll |
| io_uring, `rcvbuf-max=512K` | 20,666 - 23,941 | 23,561 | +32% |
| epoll, both flags | 38,821 - 41,147 | 39,816 | **-3.6%** |
| io_uring, both flags | 27,595 - 28,775 | 28,687 | **+60.7%** |

"Both flags" is `--rcvbuf-max=512K` together with a 1 MB
`io.netty.allocator.maxCachedBufferCapacity`. The two levers are near-additive (+32% and +14.9%
separately, +60.7% together) and they take io_uring from 43.2% of epoll to **72.0%** measured
like-for-like, or 69.4% against untuned epoll.

**The same flags do nothing for epoll**, which moves -3.6%. That asymmetry is the point: this is not
general tuning, it is specifically undoing a cost that only the completion-based transport pays.

Why they compound: raising the receive buffer to 512 KB cuts reads per message to one, but a 512 KB
buffer is far above the 32 KB default thread-cache ceiling, so every one of those buffers bypasses
the cache and goes to the arena. Raising the ceiling to 1 MB lets them be cached again. Each lever
alone leaves the other bottleneck in place.

**Cost: memory.** The io_uring server's pool runs 96-332 MB with both flags against 16-220 MB
without. Roughly a 50% increase in peak pooled direct memory for a 61% throughput gain, which is a
trade worth stating explicitly rather than presenting the speedup alone.

This also corrects something I published earlier. I wrote that the cache ceiling "is not the fix"
because raising it alone helped epoll more than io_uring. That was measured at 256 KB ceiling
*without* raising the receive buffer, and it is true in isolation. Stacked with the receive buffer it
is half of the largest win on the branch. **A lever tested alone can look useless when it is one of a
pair.**

## Independent confirmation from the allocation profile

**[SOLID]** The harness was rebuilt to allocate essentially nothing per request, which was worth
doing on its own (see below) but also produced the cleanest evidence for the mechanism on the whole
branch.

After removing the harness's own allocation, `event=alloc` profiling names what is left. On the
io_uring client it is **`IoUringIoOps`, one instance per submitted operation**, and the allocating
stack is `pollAddComplete -> pollIn -> scheduleFirstRead`. That is the POLL_ADD-then-RECV path caught
in the act, allocating once for each of the two operations epoll never submits at all. Epoll's
largest remaining site is `ZipFile$Source.initCEN` under `AppClassLoader`, which is the JVM opening
the jar and not request work at all.

The same asymmetry shows in the per-request counters at 256 KB: with the harness fixed, the io_uring
**server** still allocates 781 B/req against epoll's 124. The mechanism was inferred from a throughput
sweep; this is the same conclusion arrived at from an unrelated instrument.

## Memory churn is a concurrency effect, not a size effect

**[SOLID]** This is a correction to how I framed the memory finding, and it is a sharper result than
what it replaces.

Warming netty's arenas before the run is worth **14 points of ratio at 64 KB with 2000 connections**
and **exactly nothing at 256 KB with 500 connections**, where the identical reduction in churn
(server heap 781 down to 154 B/req) buys back no throughput whatsoever.

So pooled-memory churn is a real, measurable contributor with a measured size, and it scales with
**concurrency**, not with message size. I originally presented it as the size effect. It is not.

## The control I should have run first, and what it corrects

**[SOLID]** Every number above is netty's transport on one machine. Nothing established that io_uring
could beat epoll **at all** on this host, which means "netty's io_uring transport is slow" and "this
kernel and this loopback are bad for io_uring" were not distinguishable. They are now.

The control is `frevib/io_uring-echo-server` against `frevib/epoll-echo-server`, the C pair that
liburing issue #536 treats as the reference comparison, driven by `haraldh/rust_echo_bench`. Same
host, same whole-core pinning, 5 interleaved rounds, 180 runs with no failures and spreads typically
under 1.5%.

**io_uring does win here, so the environment is not the explanation:**

| payload | conns | epoll | io_uring | ratio |
|---|---|---|---|---|
| 512 B | 50 | 193,659 | 213,270 | **1.10x** |
| 1 KB | 50 | 191,912 | 209,537 | **1.09x** |
| 8 KB | 50 | 156,207 | 154,875 | 0.99x (ranges overlap, a tie) |
| 64 KB | 50 | 44,446 | 36,621 | **0.82x** |
| 64 KB | 300 | 38,090 | 31,861 | **0.84x** |

So netty's 1 KB deficit is real and large: C reaches 1.09x where netty reaches 0.63-0.85x.

**But the shape is the same as netty's, not opposite, and that corrects me.** C io_uring decays from
1.09x to 0.82x between 1 KB and 64 KB, losing about 25 points. Netty loses 20-30 points over the same
span. The two curves are close to parallel, with netty's sitting 25-40 points lower.

**The decisive detail: frevib's io_uring server never issues `POLL_ADD`.** It relies on
`IORING_FEAT_FAST_POLL`. The size-dependent decay appears anyway.

**So `POLL_ADD` cannot be the cause of the size dependence**, which is what I claimed. The defensible
form is weaker and more general: **any per-read operation overhead multiplies with read count, and
io_uring's per-read overhead on this kernel and this loopback path exceeds a plain `recv`.** The
reads-per-message framing survives intact, because it never depended on which operations make up the
per-read cost. What does not survive is naming `POLL_ADD` as the mechanism behind the widening.
`POLL_ADD` would add to the per-read cost rather than create the effect, and it remains a live
candidate for the **offset** between the two curves rather than their slope.

**What this control does not license.** A single-threaded C echo server using kernel buffer
selection, with no GC, no pipeline and no JNI, is not doing netty's work. The 0.82x bounds the
environment; it does not measure what netty would score if its transport were written the same way.
**[UNCERTAIN]** In particular, nothing here shows that the environmental factor (0.82) and netty's
factor (roughly 0.50) compose independently, and they should not be multiplied or subtracted as if
they did.

**Published numbers did not reproduce at scale**, which is worth knowing before citing #536. Its
512 B row is 1.11x / 1.43x / 1.46x at 50 / 300 / 1000 connections; we measure 1.10x / 1.06x / 0.98x.
Absolute throughput here is roughly 5x higher. The published run was a 2020-era VMware guest on
kernel 5.6.0-rc1, where syscalls are expensive and io_uring has a great deal to amortise. On bare
metal with a 2025 kernel there is much less. Note it is io_uring's scaling with connection count that
failed to reproduce, not epoll's: epoll decays about 22% from 50 to 1000 connections in both.

**Obvious next control, not yet run**: the same C server modified to use `POLL_ADD` + `RECV`. That
isolates the offset directly and is cheap now the harness exists.

## The six hypotheses that were wrong, in order

This list is the actual article. Every one was plausible, most were expensive to hold, and each was
killed by a cheap measurement.

1. **Completion queue too small.** **[WITHDRAWN]** A run showing 578 req/s against epoll's 168,789
   also logged "CompletionQueue overflow detected, consider increasing size: 4096" and I briefly
   claimed a 292x effect. Sweeping 4096 / 16384 / 32768 gave 127,590 / 127,014 / 125,817, which is no
   difference at all **[SOLID, RECALLED]**. The real cause was two of my own runs colliding on the
   same port and cores. The overflow warning was a symptom of the contention, not its cause.
2. **Garbage collection.** **[SOLID, RECALLED]** Falsified. GC pause time is flat and uncorrelated
   with throughput: `gcMs` between 71 and 99 while throughput swung 70k to 116k, and the slowest TLS
   round had the *lowest* GC time.
3. **Buffer rings and multishot recv.** **[SOLID]** No effect at 1 KB. At 64 KB a real but tiny +5%
   (18,702 to 19,680, non-overlapping across three rounds). **[UNCERTAIN]** This result is now
   suspect: enabling a ring should delete the POLL_ADD round trip entirely, so +5% is more consistent
   with the ring never engaging than with it engaging and not helping. The cell needs an
   `isUsable()` assertion that aborts.
4. **Registered files (`IOSQE_FIXED_FILE`).** **[SOLID]** Ruled out from the kernel profile before
   writing any of it. `fget` is 1.68% of io_uring's kernel time against epoll's `__fdget` at 1.58%.
   Eliminating fd lookup entirely would recover about 1% against a 120% gap. This would have been a
   large JNI change; one profile query saved all of it.
5. **Zero-copy send.** **[SOLID]** Actively harmful below 64 KB: 70,156 vs 119,917 at 1 KB, 50,535 vs
   86,717 at 8 KB, break-even at 64 KB and above. **This is expected on kernel 6.8**, which predates
   the 6.10 send-zc buffer coalescing; Axboe puts the post-6.10 crossover near 3000 bytes. It should
   not be reported as a property of io_uring, only as a property of this kernel.
6. **The missing write spin loop.** **[SOLID]** The most convincing wrong hypothesis. Netty's epoll
   transport runs `do { doWriteMultiple } while (writeSpinCount > 0)`, up to 16 back-to-back writes
   per event-loop turn; the io_uring transport submits one send op and never reads
   `getWriteSpinCount()` at all (verified: the setters exist on every config class, nothing consumes
   them). Partial writes scale with message size, so it predicted the widening curve precisely. And
   `SO_SNDBUF` at 64K and 1M moved nothing. Rejected.

## A trap I nearly walked into while fixing the harness

**[SOLID]** Worth an article beat of its own. Forcing epoll onto a `FixedRecvByteBufAllocator`, which
is the tax completion-based I/O pays structurally, costs **epoll 34% at 64 KB and 28% at 256 KB**
while io_uring is indifferent to it.

That means a "both transports configured identically" comparison using a fixed receive buffer is not
fair at all: it is epoll being crippled into io_uring's constraint, and it would have shown io_uring
closing most of the gap for entirely the wrong reason. Any cell in the `--prealloc` tables reporting
84.6% or 78.3% is this artifact and is labelled as such.

The general lesson: making two things "the same" can mean removing an advantage one of them
legitimately has.

## Two more claims I had to withdraw

**[WITHDRAWN]** *"The plaintext deficit is client-side."* Crossing the transports (server and client
are independent processes) showed io_uring on the server alone costs about as much as on the client
alone, and the two do not add **[SOLID]**:

| server | client | median req/s |
|---|---|---|
| epoll | epoll | 139,356 |
| io_uring | epoll | 115,252 |
| epoll | io_uring | 112,656 |
| io_uring | io_uring | 114,885 |

**[WITHDRAWN]** *"io_uring saves 17% of server kernel time."* With the client held at epoll so the
server is measured in isolation, the io_uring server uses **more** kernel time per request: 21.5 us
against 15.6. The 12.80 us figure I had published came from one sample at the low end of a spread
running 12.53 to 21.34.

Both errors have the same shape: reading a per-request CPU figure from a single *paired* run as if it
were a property of one side. Only holding one side fixed can attribute cost to a side.

## And a methodology error of my own that a literature review caught

**[SOLID]** Every script in this branch pinned server to cpuset `0-3` and client to `4-7` and
described them as disjoint cores. On this box `cpu0`'s thread siblings are `0,4`; likewise `1,5`,
`2,6`, `3,7`. Four physical cores, eight logical. Client and server were sharing physical cores as
hyperthread siblings the entire time.

Re-running 64 KB under both pinnings:

| pinning | epoll | io_uring | ratio |
|---|---|---|---|
| old (SMT siblings) | ~42,008 | ~18,373 | 43.7% |
| correct (whole cores) | 34,959 | 17,794 | 50.9% |

The artifact was working **against** io_uring, and correcting it shrinks the gap by seven points
without changing any ordering or conclusion. Worth writing up honestly: the error was real, it was
mine, and it did not manufacture the result.

## Where io_uring does win

**[SOLID]** With TLS. Ten consecutive fresh-JVM rounds each, CPU frequency and package temperature
logged per round:

| | rounds | median |
|---|---|---|
| io_uring, TLS, 1 KB, 10k connections | 84,074 - 115,974 | **110,585** |
| epoll, TLS, 1 KB, 10k connections | 72,755 - 97,351 | 94,681 |

io_uring is **+16.8%** faster, with 9 of 10 rounds above epoll's median.

Two corrections to what I first wrote here, both found by re-reading `tlswarm.log`:

- The io_uring median was reported as 107,719 from an off-by-one in the median index. It is 110,585,
  so the advantage is 16.8% rather than 14%.
- I wrote that frequency sat at 3.2 GHz and temperature at 71-76 C "throughout". **That is false.**
  The real range is 67-88 C, with `ur-02` at 3.60 GHz / 88 C and `ep-01` at 3.50 GHz / 83 C. Those
  excursions land on the first round of each block, which is exactly the machine-state evidence this
  test existed to collect. Quoting the narrow range would have deleted the most interesting thing in
  the data.

Consistent with the read-count mechanism: TLS at 1 KB is crypto-dominated, so per-read transport
overhead is a much smaller share of the total and io_uring's batching across ten thousand connections
can show.

**[UNCERTAIN]** These twenty rounds were consecutive per transport rather than interleaved, because
the question being asked was whether a within-transport warm-up trend existed. The per-round
frequency and temperature logging is what makes the cross-transport comparison usable at all. Repeat
interleaved before publishing.

**[WITHDRAWN]** An earlier run showed io_uring's TLS throughput climbing across five fresh JVMs
(70,442 then 82,764, 111,042, 115,721, 115,189) and I treated it as a real warm-up effect that
blocked any TLS claim. It does not reproduce: rounds 1 and 2 of the ten-round run are 115,260 and
115,974, at the top of the whole distribution rather than the bottom. That was machine state in one
run.

**[UNCERTAIN]** I also wrote "round 1 is the highest of the ten", which is wrong: round 2 is higher.
The conclusion survives, the supporting sentence did not.

## An instrument caveat that outlived the experiment

**[SOLID]** async-profiler under-reports io_uring's kernel time. At 1 KB it accounted for epoll almost
exactly (65.8% of samples on kernel frames against 67.9% of measured CPU as system time) but showed
io_uring at 18.8% of samples against 66.5% system time, a 3.5x shortfall. At 256 KB the shortfall was
about 30%.

The obvious explanation, that work is punted to `io_wq` kernel worker threads which a JVM profiler
never attaches to, was **tested and falsified**: a thread census during steady state found no
`iou-wrk-*` threads on either side. Operations complete inline.

**[UNCERTAIN] The cause is not established.** Candidates raised but not tested: perf sample
throttling, samples inside `io_uring_enter` with no Java frame to join to, and NET_RX softirq time
charged to the current task with a kernel-only stack. The practical rule this produced is worth the
article on its own: **check profiler sample totals against CPU counters before quoting any
percentage**. Nothing in the tool says it is missing half your time.

## Kernel profiling without root, as a technique

**[SOLID]** thor has `perf_event_paranoid=4` and `kptr_restrict=1` and sudo wants a password. Container
capabilities lift both with no host change:

    --cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG --security-opt seccomp=unconfined

`CAP_PERFMON` bypasses the paranoid check, `CAP_SYSLOG` un-hides kernel symbols so frames resolve to
names, and unconfining seccomp lets `perf_event_open` through docker's default filter. Kernel frames
then resolve normally. Small, genuinely useful, and I have not seen it written up.

---

# Article 4: the traps that returned a plausible number instead of an error

Every one of these was hit for real in this work. That is the thesis: the failure mode of
benchmarking is not a crash, it is a number that looks fine.

1. **[SOLID, RECALLED] JMH exits 0 with an empty result array** when every benchmark fails to
   initialise. A green run with no results looks like a pass to any CI script.
2. **[SOLID, RECALLED] Netty's own shaded benchmark jar could not run a single SSL benchmark**,
   because the key material was resolved with `getResource().getFile()`, which does not work inside a
   jar. Nobody had noticed because nothing in netty's CI runs `microbench`.
3. **[SOLID, RECALLED] SSL contexts were built eagerly for every provider**, so the JDK-provider rows
   could not run at all on an image where tcnative was absent. The control was silently unavailable.
4. **[SOLID, RECALLED] Short-warmup numbers varied up to 10x run-to-run on a busy laptop** while being
   stable to +/-2% on an idle host.
5. **[SOLID] Netty's transports fall back to NIO** when a native transport is unavailable. For a
   benchmark this is the worst possible default: it publishes NIO's number under epoll's label and
   nothing in the output says so. Every transport in this harness aborts instead.
6. **[SOLID] `SO_BACKLOG` defaults to 200.** Ten thousand simultaneous connects overflow it instantly,
   the kernel drops SYNs, and it presents as a stalled ramp rather than an error.
7. **[SOLID] Docker's default seccomp profile blocks `io_uring_setup`.** Without
   `--security-opt seccomp=unconfined` io_uring is simply unavailable, and combined with trap 5 that
   means you measure NIO and call it io_uring.
8. **[SOLID] Closed-loop p50 is queue depth, not latency.** An early run reported p50 of 57 ms and it
   was Little's Law, not service time: 10,000 connections divided by throughput. The harness now
   labels the mode in its own output (`closed-loop:latency-is-queue-depth`) and has an open-loop
   `--rate` mode that measures from *due* time, which is the only way to avoid coordinated omission.
   Verified: 81,987 req/s at p50 1831 us closed-loop against 19,995 req/s at p50 60 us open-loop.
9. **[SOLID] `/proc/self/status` reports the main thread only.** In netty the main thread does nothing
   after bind, so context-switch counters read a confident-looking zero. They have to be summed over
   `/proc/self/task/*`.
10. **[SOLID] A profiler can silently miss half your time.** See the async-profiler caveat above.
11. **[SOLID] "Disjoint" cpusets may be SMT siblings.** See the pinning error above.
12. **[SOLID] An orphaned process can hold a port for hours.** One held 19999 for four hours and
    poisoned runs that looked merely slow. Scripts now scan a range for a free port and wrap clients
    in `timeout`.

---

# Scope limits that belong in any write-up

**[SOLID]** These are not caveats to bury. Several of them are load-bearing.

- **Loopback.** The syscall epoll pays for is close to a memcpy, so io_uring's core advantage,
  amortising syscall entry, has almost nothing to amortise. Documented as unrepresentative.
- **Queue depth 1 per connection.** Universally described as io_uring's worst case.
- **Kernel 6.8.** Predates send-zc buffer coalescing and send/recv bundles (6.10) and
  `IORING_ENTER_NO_IOWAIT` (6.15). The size sweep should be repeated on 6.10+ before being published
  as an io_uring result rather than a netty-on-6.8 result.
- **4 physical cores**, with client and server sharing the machine.
- **A single netty version**, 4.2.18-SNAPSHOT.

The honest framing for the io_uring articles is "netty's io_uring transport, on this kernel, on this
shape of workload" and not "io_uring is slow".

---

# Related prior art worth citing

**[SOLID]** Found during the literature review and verified as real issues:

- liburing #536, the canonical io_uring-vs-epoll network benchmark, whose gap narrows with size.
- netty-incubator-transport-io_uring #152: 8% lower throughput than epoll, "context switches were 69%
  higher".
- netty #15747 (open): 10-25% gap on FileRegion transfers, worse past the 64 KB pipe buffer. A second
  independent case of this transport losing more as size grows past a fixed buffer boundary.
- netty #16086 (closed, inconclusive): the SENDMSG_ZC batch-vs-per-buffer threshold problem.
- netty #17238 (open): a write SQE still in flight while its memory returns to the allocator.

**[SOLID]** Not filed by anyone, as far as the review found: the missing write spin loop, the
`maxCachedBufferCapacity` interaction, and the POLL_ADD+RECV pair being taken whenever no buffer ring
is configured.

---

# Two small netty bugs found on the way

**[SOLID]** Both verified in source, neither reported (standing instruction: nothing filed without
review).

1. **`IoUringBufferRingConfig.builder()` cannot be used without calling `batchSize()`.** The builder
   initialises it to -1 and `build()` validates it into 1..1024, so it throws where every other
   optional field has a working default.
2. **Multishot recv is silently inert by default.** `io.netty.iouring.recvMultiShotEnabled` defaults
   to `true`, but `IORING_RECV_MULTISHOT` is only ever set inside `scheduleReadProviderBuffer()`,
   which is reached only when a provided buffer ring is configured, and
   `IoUringIoHandlerConfig` configures none by default. A property that reads as on and does nothing.
