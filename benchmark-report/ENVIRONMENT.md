# Runtime environment for benchmarks

What this work established about *where and how* to run a benchmark, as distinct from what it
measured. Companion to `FINDINGS.md` (conclusions) and `TESTS.md` (evidence).

Almost everything here was learned by getting it wrong first. Each entry says what the wrong answer
looked like, because the recurring lesson is that a bad environment does not produce an error. It
produces a number.

Confidence tags as elsewhere: **[SOLID]** verified here, **[SOLID, RECALLED]** measured but reaching
this document through a summary, **[UNCERTAIN]** named gaps.

---

## 1. The host

### 1.1 CPU topology, and the trap that caught me

**[SOLID]** Every script in this branch pinned the server to cpuset `0-3` and the client to `4-7`,
described them as "disjoint cores", and was wrong. On the test host:

```
$ cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
0,4
```

Four physical cores, eight logical. `0-3` and `4-7` are exactly the SMT sibling pairs, so client and
server shared physical cores for months of measurement.

**Cost of the error, measured both ways** at 64 KB:

| pinning | epoll | io_uring | ratio |
|---|---|---|---|
| `0-3` vs `4-7` (siblings) | ~42,008 | ~18,373 | 43.7% |
| `0,1,4,5` vs `2,3,6,7` (whole cores) | 34,959 | 17,794 | 50.9% |

Seven percentage points, and it was working *against* the transport under test. It changed no
ordering, but it would have changed a published magnitude.

**Rule**: never infer topology from cpuset numbering. Read `thread_siblings_list` for every CPU and
build cpusets from whole physical cores. Note that correct pinning gives each side *fewer* real
cores, so absolute throughput drops even as the comparison gets honest.

### 1.2 Load average is not a busy-ness signal

**[SOLID]** I once read a load average of 7.07 on an 8-logical-core box as "at capacity" and paused
work. `vmstat` showed 97 to 98% idle with a run queue of 0 to 1. Later the same host showed a load
average of 7.94 while 96% idle.

**Rule**: `vmstat 1 3` and read the idle column and run queue. Load average on Linux counts
uninterruptible sleepers and is close to useless for this.

### 1.3 Frequency and temperature must be recorded per round, not assumed

**[SOLID]** An earlier run showed io_uring's TLS throughput climbing across five fresh JVMs (70,442
then 82,764, 111,042, 115,721, 115,189). It looked like a warm-up effect and it blocked a real
finding for days.

It did not reproduce. Ten consecutive rounds later, round 1 was the highest of the ten. The reason
the second run was conclusive and the first was not is that the second logged `freqKHz`,
`tempMilliC` and `load1m` per round, so "the machine was in the same state throughout" became a
measurement instead of an assumption. Frequency sat at 3.2 GHz and temperature at 71 to 76 C.

**Rule**: sample `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` and a thermal zone per round
and put them in the result row. Without them you cannot distinguish thermal throttling, turbo
residency and a real effect.

**[UNCERTAIN]** The CPU governor was never checked or pinned on this host. It should be set to
`performance` for benchmarking, and recorded either way.

### 1.4 Orphaned processes hold ports for hours

**[SOLID]** A root-owned client process held port 19999 for four hours after its parent died. Runs
against it did not fail; they were merely slow, which is the worst possible symptom. A separate
incident had an ssh `RemoteForward 8931` in `~/.ssh/config` silently occupying a port.

**Rule**: scan a range for a genuinely free port at the start of every run, and wrap every client in
`timeout`. Both are in the harness now:

```bash
for p in $(seq 19990 20050); do
  if ! ss -tln | grep -q ":$p "; then PORT=$p; break; fi
done
```

### 1.5 One machine, one benchmark

**[SOLID]** The single worst measurement in this work claimed a 292x effect from io_uring completion
queue size. The real cause was two of my own runs colliding on the same port and cores. A sweep of
4096 / 16384 / 32768 later gave 127,590 / 127,014 / 125,817, which is no effect at all.

The "CompletionQueue overflow detected" warning that appeared alongside it was a *symptom* of the
contention, not its cause, and it was persuasive enough to publish a wrong number.

**Rule**: serialise runs on a host, and treat any warning that appears during a contended run as
untrustworthy evidence.

---

## 2. The container

### 2.1 Docker's default seccomp blocks `io_uring_setup`

**[SOLID]** Without `--security-opt seccomp=unconfined`, io_uring is simply unavailable inside the
container.

This is dangerous in combination with 2.2. Netty's transports fall back to NIO when a native
transport is unavailable, so the default configuration measures NIO and labels it io_uring, with
nothing in the output saying so.

### 2.2 Netty falls back to NIO silently

**[SOLID]** For a benchmark this is the worst possible default. Every transport in this harness calls
an `ensureAvailable()` that throws:

```java
if (!IoUring.isAvailable()) {
    throw new IllegalStateException("io_uring is not available", IoUring.unavailabilityCause());
}
```

**Rule**: a benchmark must abort when the thing under test is missing. Never fall back. The same rule
applies to any feature-gated path: a cell labelled "buffer ring" that silently ran without one is
worse than no cell.

**[UNCERTAIN]** This bit us: the buffer-ring result (+5% at 64 KB, nothing at 1 KB) is now suspect
precisely because the cell never asserted `IoUringBufferRing.isUsable()` at runtime, and the numbers
fit "the ring never engaged" better than "it engaged and did not help".

### 2.3 ulimits the workload actually needs

**[SOLID]**

| limit | value | why |
|---|---|---|
| `nofile` | `65536:65536` | 10k connections is ~20k descriptors on loopback |
| `memlock` | `-1` | `IORING_OP_SEND_ZC` pins pages; too low gives `-ENOMEM` and failed writes |

### 2.4 `SO_BACKLOG` defaults to 200

**[SOLID]** Netty's default. Ten thousand simultaneous connects overflow it instantly, the kernel
starts dropping SYNs, and it presents as a stalled ramp rather than an error. Needs ~8192, with
`net.core.somaxconn` raised to match.

### 2.5 cgroup accounting shows up in your profile

**[SOLID]** `page_counter_try_charge` and `refill_stock` appeared in kernel profiles at 1.26% and
1.78%. That is a container tax that would not exist on bare metal. It is small, but it is real and it
belongs in the write-up rather than being quietly attributed to the workload.

### 2.6 libc: matters for the library, not for the transport

**[SOLID]** A glibc control (`eclipse-temurin:21-jdk`) against the Alpine/musl cell at 64 KB gave
epoll 39,149 to 42,217 and io_uring 19,155 to 19,893: the same ~48% ratio. **musl is not a factor in
the transport comparison.**

**[SOLID, RECALLED]** It is very much a factor for native libraries. Released netty-tcnative 2.0.81
fails on Alpine two different ways depending on architecture (catchable `UnsatisfiedLinkError` on
x86_64, uncatchable SIGSEGV on aarch64). See `FINDINGS.md` article 2.

**Rule**: run a glibc control before attributing anything to musl.

---

## 3. The kernel

**[SOLID]** Kernel version dominates io_uring results, and the test host at 6.8.0-57-generic is
behind the features that matter:

| feature | lands in | consequence here |
|---|---|---|
| send-zc buffer coalescing | 6.10 | our SEND_ZC result (harmful below 64 KB) is a property of 6.8, not of io_uring. Axboe puts the post-6.10 crossover near 3000 bytes |
| send/recv bundles | 6.10 | the feature most likely to help large transfers, absent |
| `IORING_ENTER_NO_IOWAIT` | 6.15 | without it, CQ-waiters are accounted `in_iowait`, which inflates `%iowait` and can trigger cpufreq iowait-boost, so two transports may run at different frequencies |

**Rule**: record `uname -r` in every result row, and never frame a kernel-feature-sensitive result as
a property of the technology when it is a property of your kernel. Any io_uring size sweep should be
repeated on 6.10 or newer before publication.

---

## 4. Observability prerequisites

### 4.1 Kernel profiling without root, without changing the host

**[SOLID]** The host had `perf_event_paranoid=4` and `kptr_restrict=1`, and sudo wanted a password.
Container capabilities lift both, per-container, with no host sysctl change:

```
--cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG --security-opt seccomp=unconfined
```

`CAP_PERFMON` bypasses the paranoid check, `CAP_SYSLOG` un-hides kernel symbols so frames resolve to
names rather than addresses, and unconfining seccomp lets `perf_event_open` through. Kernel frames
then resolve normally (`do_syscall_64`, `io_uring_enter`, `tcp_*`). Nothing is left behind for the
next user of the machine.

Without capabilities, async-profiler's `event=ctimer` mode works (POSIX timers, no privileges) but
produces **no kernel stacks at all**, which is why the first profiles missed the interesting half.

### 4.2 Always check profiler sample totals against CPU counters

**[SOLID]** This is the single most transferable thing in this document.

| | system time share of measured CPU | share of samples on kernel frames |
|---|---|---|
| epoll | 67.9% | 65.8% |
| io_uring | 66.5% | **18.8%** |

epoll's profile accounts for itself almost exactly. io_uring's kernel time was under-reported by
3.5x at 1 KB and ~30% at 256 KB. Nothing in the tool said so. Reading the percentages at face value
would have understated one transport's kernel share by a factor of three.

The obvious explanation was tested and **falsified**: a thread census during steady state found no
`iou-wrk-*` threads, so nothing was punted to io_wq and operations complete inline.

**[UNCERTAIN] The cause remains unknown.** Untested candidates: perf sample throttling, samples
inside `io_uring_enter` with no Java frame to join to, and NET_RX softirq time charged to the current
task with a kernel-only stack.

**Rule**: sum the sample counts, compare against `utime + stime` from `/proc/self/stat`, and refuse to
quote a percentage until they agree.

### 4.3 Cheap counters before expensive profilers

**[SOLID]** The ordering that worked: process counters first to find *which bucket* the cost is in,
profiler second to find *which frames*. Reversing it wastes the profiler on the wrong process, and in
this case would have produced an authoritative-looking answer that was wrong by 2x.

Counters worth having, all free:

- `/proc/self/stat` fields 14 and 15 for user and system time. Parse **after the last `)`**, because
  the `comm` field can contain spaces and parentheses, and index-based tokenising silently produces
  nonsense otherwise.
- `GarbageCollectorMXBean` for pause count and time.
- Context switches summed over `/proc/self/task/*/status`, **not** `/proc/self/status`. The latter
  reports the main thread only, and in netty the main thread does nothing after bind, so it returns a
  confident-looking zero.
- Allocator state, when the allocator is implicated: `usedDirectMemory()` and live chunk count.

### 4.4 Measure the load generator too

**[SOLID]** At 256 KB the dominant client-side frame turned out to be the harness's own payload
construction (`writeZero`), not netty. It was identical work in both arms so it did not bias the
comparison, but it consumed a large share of client CPU and would have been misread as a transport
cost if only the aggregate had been examined.

**Rule**: profile both sides, and know which of your own frames are in the way.

---

## 5. Measurement mode

### 5.1 Closed-loop p50 is queue depth, not latency

**[SOLID]** An early run reported p50 of 57 ms. That was Little's Law: 10,000 connections divided by
throughput, not service time. Verified both ways: 81,987 req/s at p50 1831 us closed-loop against
19,995 req/s at p50 60 us open-loop.

The harness now labels its own output `closed-loop:latency-is-queue-depth` so the number cannot be
quoted innocently, and has an open-loop `--rate` mode that measures from **due** time, which is the
only way to avoid coordinated omission.

**[UNCERTAIN]** An open-loop anomaly at small payloads was never explained: p50 around 100 us against
p99 around 1 s with the target rate met.

### 5.2 Open loop is how you separate cause from effect

**[SOLID]** The most useful single experiment in this work. Under saturation, io_uring showed 2x the
pooled memory of epoll and 2x the CPU per request, which looked causal. But it was also 2.3x slower,
and slowness alone raises in-flight memory, so the comparison was circular.

Driving both at a fixed 2,000 req/s, below either's capacity, broke the circle: CPU per request
matched to within 0.3% (203.1 against 203.7 us) and the memory thrashing vanished, leaving a stable
2x footprint difference.

**Rule**: when two things are correlated under saturation, re-run at a matched sub-saturation rate.
Anything that survives is a property; anything that vanishes was a consequence of the rate.

### 5.3 Interleave, always

**[SOLID]** Every claim in this work that survived came from interleaved A/B rounds. Every claim that
had to be withdrawn came from comparing across runs or from a single run.

Grouping all of arm A then all of arm B maps machine drift directly onto the axis under test.
Round-robin spreads it across every cell instead, so a real ordering survives and a spurious one does
not.

**Rule**: at least five interleaved rounds, report the per-round spread next to the median, and if a
result's spread overlaps the cell it is compared against, report it as "not established" rather than
as a small effect.

---

## 6. CI and cloud: what they can and cannot do

### 6.1 GitHub-hosted runners cannot produce timing results

**[SOLID as reasoning, UNCERTAIN on current specs]** Standard runners are ephemeral VMs on shared
hosts. Against the requirements established above:

- **Core pinning is impossible.** The SMT error in section 1.1 would be undiagnosable; vCPU-to-core
  mapping is opaque.
- **Noisy neighbours are invisible.** One cell here swung 124k to 167k on a machine that was 96% idle
  and entirely ours. On shared infrastructure you cannot even detect that it happened.
- **Frequency and thermal state are unobservable**, so section 1.3 cannot be satisfied.
- **The hardware and kernel change underneath you** on the provider's schedule, which section 3 shows
  is decisive for io_uring.

**[UNCERTAIN]** Exact current runner specs (vCPU counts, CPU models, image kernel versions) were not
verified during this work and change often. The argument above does not depend on them.

### 6.2 What CI is genuinely for

**[SOLID]** The gate/insight split already in this project's plan:

| mode | invocation | question it answers |
|---|---|---|
| **gate** | `-f 1 -wi 1 -i 1 -r 1s -to 60s` | does it run green everywhere, on every libc, arch and provider, without throwing |
| **insight** | default forks and iterations, dedicated host | what are the numbers |

Gate mode needs no timing stability at all and is exactly what a hosted matrix is good at. Keep
timing off CI entirely.

A gate must also be honest about coverage: a skipped cell must say so, and an unavailable provider
must fail rather than fall back, or a green matrix means nothing.

### 6.3 Dedicated hardware: realistic lifespans

**[UNCERTAIN, judgement rather than measurement]**

| option | stable for | note |
|---|---|---|
| own machine | as long as you maintain it | best control, worst continuity if it dies |
| rented dedicated (Hetzner, OVH, Scaleway) | 3 to 5 years per machine | same SKU orderable for years; expect 2 to 3 migrations per decade |
| cloud bare metal (`*.metal`) | 3 to 7 years per family | families get retired |
| anything virtualised | not suitable | regardless of price |

Nothing gives a stable decade. Plan for two or three hardware eras.

---

## 7. Making results outlive the machine

Since no machine is stable for ten years, stability has to come from the method. Three things, none
implemented yet, all cheap:

**7.1 Carry a calibration workload in every run.** Something fixed and boring, reported alongside the
real result, so the real result can be expressed as a ratio to it. Then a 2036 number is comparable
to a 2026 number even though absolute throughput has tripled. Without this, ten years of absolute
numbers is ten years of unrelated numbers.

**7.2 Fingerprint the environment into every result row.** Everything this document shows can
invalidate a comparison:

```
cpu model, physical/logical core counts, thread_siblings_list, governor,
per-round scaling_cur_freq and thermal zone, kernel release, libc + version,
container runtime + seccomp/capability set, ulimits, JVM build,
netty version, cgroup memory limit, and the cpuset actually granted
```

Half the corrections in this work came from a fingerprint field existing. The other half came from
one not existing yet.

**7.3 Archive raw output, not summaries.** Every `[SOLID, RECALLED]` tag in `FINDINGS.md` exists
because a number reached a document without its raw record attached. Where raw JMH records were later
recovered from the host, those tags could be upgraded and a missing unit resolved. That recovery was
only possible because the files still happened to be there.

---

## 8. Checklist

Before trusting any run:

- [ ] `thread_siblings_list` read; cpusets built from whole physical cores
- [ ] `vmstat` idle and run queue checked, not load average
- [ ] governor recorded (ideally `performance`)
- [ ] free port scanned; client wrapped in `timeout`
- [ ] no other benchmark on the host
- [ ] `seccomp=unconfined` if io_uring is involved
- [ ] transport availability asserted, aborting rather than falling back
- [ ] feature availability asserted at runtime, not just requested
- [ ] `nofile` 65536, `memlock` unlimited if zero-copy is involved
- [ ] `SO_BACKLOG` raised above the connection count
- [ ] at least five interleaved rounds; spread reported with the median
- [ ] measurement mode labelled in the output itself
- [ ] per-round frequency, temperature and load recorded
- [ ] profiler sample totals reconciled against `utime + stime` before any percentage is quoted
- [ ] kernel release recorded, and feature-sensitive results framed accordingly
- [ ] glibc control run before attributing anything to musl
- [ ] raw output archived alongside the summary
