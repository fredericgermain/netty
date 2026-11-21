# Runbook: what happens when a sweep runs

`ENVIRONMENT.md` is organised by trap and rule, `TESTS.md` is an evidence index, `REPLICATION.md` is
the two-machine protocol. None of them says what happens *in order*, or which numbers are allowed
out of a run. This does.

It summarises and cites; it is not a second source of truth. Every figure below names the file that
holds its evidence, and if the two ever disagree, the cited file wins.

---

## 1. The four stages

| stage | command | what it refuses to do |
|---|---|---|
| **Gate** | `scripts/bench-usb.sh check` (or the rig's `bench-tuning.sh check`) | exits nonzero unless the host is in the measurement state. `apply_start` **refuses to apply anything at all** on a machine with no measured clock cap, rather than borrowing another machine's figure |
| **Calibrate** | `scripts/calibrate.sh [label]` | appends one row to `logs/calibration.tsv`; errors rather than writing `?` into a field |
| **Measure** | the sweeps in `quic/`, sourcing `quic/lib.sh` | aborts a cell instead of falling back; discards a disturbed cell instead of footnoting it |
| **Archive** | raw output committed beside the summary | -- |

**Why calibrate at all.** Absolute throughput from two machines, or one machine in two different
years, are unrelated numbers. Two fixed anchors make them comparable:

- **compute** — sha256 over a fixed 256 MiB buffer in `/dev/shm`, pinned to one core. No JVM, no
  kernel networking. Moves with clock and memory speed.
- **network** — one cheap cell through the real harness: tcp/epoll, no TLS, 1 KB, 50 connections,
  one event-loop thread. Moves with clock *and* with the kernel's network path.

Having both is the point. If the network anchor moves between machines and the compute anchor does
not, the difference is in the stack rather than the silicon, and a transport comparison taken on the
two hosts can still be read against each other. If both move by the same factor it is clock, and
every cell scales with it.

---

## 2. Host and kernel tuning

Applied by `apply_start`, reverted by `apply_stop`. Everything here is **volatile** — governor, both
`intel_pstate` percentages and the sysctls all reset on reboot. This host rebooted mid-investigation
once and silently reverted all of them, which is why there is a gate rather than a habit.

| knob | measurement value | stock |
|---|---|---|
| `scaling_governor` | `performance` | `powersave` |
| `intel_pstate/min_perf_pct` | **62** | 17 |
| `intel_pstate/max_perf_pct` | **62** | 100 |
| `/sys/firmware/acpi/platform_profile` | `performance` | `balanced` |
| `kernel.perf_event_paranoid` | 1 | 4 |
| `kernel.kptr_restrict` | 0 | 1 |
| `net.core.somaxconn` | 8192 | 4096 |

**`intel_pstate`'s names mislead**: its `powersave` governor is the *dynamic* one, not a low-power
mode. `performance` plus an equal min and max is what actually pins the clock.

**62% was derived, not chosen** (`bench-tuning.sh`, and the sweeps behind it in the rig repo):

| policy | result |
|---|---|
| `powersave` | dynamic across 800-4500 MHz. **36% throughput swing between runs of the same cell** |
| `performance`, uncapped | 100 C in 30 seconds on this chassis, then throttles continuously — up to **533 throttle events in one measured cell** |
| **62% capped, min = max** | 2593 MHz mean, 62 C, **zero** throttle events, same throughput as `powersave` |

**Capping only the maximum is not a pinned clock.** With the floor left at 17, one run spanned
**65,767-101,292 req/s, a 54% spread**, while the recorded per-side frequency moved only
2528-2752 MHz. `min_perf_pct` is set equal to `max_perf_pct` deliberately.

**The clock cap is per machine and must be measured.** 62 is the XPS 15 9500's figure. The table in
`scripts/bench-usb.sh` is keyed on `/sys/class/dmi/id/product_name`, and a machine absent from it is
refused. Derive a new one with the rig repo's `sweeps/coresweep3.sh`.

**Thermal mode is the only fan lever this hardware exposes**, and it is sysfs, not a package:
`libsmbios-bin` does not exist in Ubuntu 26.04, so `smbios-thermal-ctl` is gone. Writing
`platform_profile` drives the same firmware setting — verified that `performance` moves
`dell-wmi-sysman`'s `ThermalManagement` from `Optimized` to `UltraPerformance`. Why it matters, from
`csv/fan-ramp-balanced.csv` in the rig repo:

| package | `Balanced` | `Performance` |
|---|---|---|
| 86 C | fans **0 RPM** | -- |
| 90 C | -- | 2812 / 3120 RPM |
| 94 C | fans **0 RPM** | -- |
| 97 C | fan1 first moves (1261 RPM) | -- |
| 100 C | 3233 / 3507 | 3225 / 3513 |

Both modes plateau at ~3240/3510, so the mode moves **when** the cooling engages, not how hard it
can work. There is no throttle-free core count at unrestricted turbo — even one busy core throttles,
because single-core turbo is a high-voltage state. The limit is clock, not core count.

---

## 3. Pinning

`scripts/topology.sh` reads `thread_siblings_list` for every CPU and builds cpusets from **whole
physical cores**. Never infer topology from cpuset numbering.

The trap that forced this (`ENVIRONMENT.md` §1.1): on this host `cpu0`'s siblings are `0,4`. Four
physical cores, eight logical — so the long-standing "server `0-3`, client `4-7`, disjoint cores" was
exactly the SMT sibling pairs, and client and server shared physical cores for months. Measured both
ways at 64 KB:

| pinning | epoll | io_uring | ratio |
|---|---|---|---|
| `0-3` vs `4-7` (siblings) | ~42,008 | ~18,373 | 43.7% |
| `0,1,4,5` vs `2,3,6,7` (whole cores) | 34,959 | 17,794 | 50.9% |

Seven percentage points, working *against* the transport under test. It changed no ordering but it
would have changed a published magnitude. Note that correct pinning gives each side fewer real cores,
so absolute throughput **drops** as the comparison gets honest.

Load average is not a busy-ness signal: 7.07 on an 8-logical-core box turned out to be 97-98% idle
with a run queue of 0-1. Use `vmstat 1 3` and read the idle column and run queue.

---

## 4. Latency: the part most easily quoted wrongly

`LoadTest.java` has two modes and **labels which one produced a number, in the output itself**, so a
figure cannot be quoted innocently.

### Closed loop — the default, no `--rate`

One request in flight per connection; send the next when the previous returns. Saturates the system
and measures **maximum throughput**. Its latency figures are *not* service times: with N connections
all pushing, Little's Law fixes p50 at roughly N/throughput regardless of how fast the stack is, so
what they report is the queue depth the operator chose. An early run reported p50 = 57 ms, which was
10,000 connections divided by throughput and nothing more.

### Open loop — `--rate=N`

Each connection sends on a fixed schedule derived from the target rate, independently of whether
earlier requests came back. **Latency is measured from the time a request was *due* to be sent**, not
when it actually went out, which is what stops a stalled system from hiding its own delay — the
coordinated omission problem.

Due times are kept in a primitive `long[1024]` ring rather than an `ArrayDeque<Long>`, because a
nanotime value is far outside the `Long` cache and would mean a guaranteed heap allocation per
request *on the axis being measured*. The tickers are staggered across one interval, or 10k
connections all fire in the same millisecond and the load arrives as a spike rather than at the rate.

Verified both ways: **81,987 req/s at p50 1831 us closed-loop** against **19,995 req/s at p50 60 us
open-loop**.

### The three mode labels, verbatim

| label | when |
|---|---|
| `closed-loop:latency-is-queue-depth` | no `--rate` |
| `open-loop:target-met` | achieved >= **95%** of target |
| `open-loop:TARGET-MISSED-<n>%:percentiles-invalid` | below that |

Percentiles from an open-loop run only mean anything if the offered rate was actually achieved.
Quoting them from a missed run is the same mistake as quoting closed-loop p50.

### Sub-saturation is how you separate cause from effect

The most useful single experiment in this work. Under saturation io_uring showed 2x epoll's pooled
memory and 2x the CPU per request, which looked causal — but it was also 2.3x slower, and slowness
alone raises in-flight memory, so the comparison was circular. Driving both at a fixed 2,000 req/s,
below either's capacity, broke the circle: CPU per request matched to within **0.3% (203.1 against
203.7 us)** and the memory thrashing vanished, leaving a stable 2x footprint difference.

**Rule**: when two things correlate under saturation, re-run at a matched sub-saturation rate.
Anything that survives is a property; anything that vanishes was a consequence of the rate.

**[UNCERTAIN]** One open-loop anomaly at small payloads was never explained: p50 around 100 us
against p99 around 1 s, with the target rate met.

---

## 5. What every cell records, and what throws it away

`quic/lib.sh` samples every 0.5 s through the measured window, and checks for foreign containers
every fourth sample. Eleven columns, appended to every row:

```
mhzMin  mhzMax  mhzMean  srvMhz  cliMhz  tempMaxC  throttleDelta  contended  waited  wifiDelta  usbDelta
```

A cell is **discarded, not footnoted**, on any of:

- `contended` — a foreign container seen at any point inside the window. Contention has been observed
  to **invert a transport ordering**, not merely add noise.
- a nonzero `throttleDelta`.
- an outlying `wifiDelta` (interrupt/packet deltas on the wireless link) or `usbDelta` (KiB written
  and write IOs on the USB key, which on the replication key holds docker's data-root).

`waited` records that the quiet gate paused before the cell. Pausing beats measuring through a
neighbour, but a round containing a pause is not equivalent to one that ran straight through, because
interleaving protects a comparison by giving every cell in a round the same machine state.

**Interleave, always.** At least five rounds, round-robin, never all-of-A-then-all-of-B — grouping
maps machine drift directly onto the axis under test. Report the per-round spread next to the median,
and **if a result's spread overlaps the cell it is compared against, it is "not established", not a
small effect.** Every claim in this work that survived came from interleaved rounds; every claim
withdrawn came from comparing across runs or from a single run.

Frequency and temperature are recorded per round, not assumed. An apparent warm-up effect — io_uring
TLS throughput climbing across five fresh JVMs — blocked a real finding for days and did not
reproduce; ten rounds later, round 1 was the highest of the ten.

---

## 6. The kernel-version ceiling

Every published figure in this repository was taken on **6.8.0-57-generic**, which is behind the
io_uring features that matter (`ENVIRONMENT.md` §3):

| feature | lands in | consequence here |
|---|---|---|
| send-zc buffer coalescing | 6.10 | the SEND_ZC result (harmful below 64 KB) is a property of 6.8, not of io_uring |
| send/recv bundles | 6.10 | the feature most likely to help large transfers — absent |
| `IORING_ENTER_NO_IOWAIT` | 6.15 | without it CQ-waiters are accounted `in_iowait`, inflating `%iowait` and able to trigger cpufreq iowait-boost — so two transports may run at **different frequencies** |

Record `uname -r` in every row, and never frame a kernel-feature-sensitive result as a property of
the technology when it is a property of your kernel. **thor now runs 7.0.14**, so all three are
present and repeating the io_uring size sweeps is the highest-value open item here — no longer
blocked on hardware.

---

## 7. Non-negotiables, every run

- `--security-opt seccomp=unconfined` if io_uring is involved. Docker's default profile blocks
  `io_uring_setup`, and combined with silent NIO fallback that means measuring NIO and calling it
  io_uring.
- **Assert, never fall back.** Netty silently drops to NIO when a native transport is unavailable,
  publishing NIO's number under epoll's label. Every cell asserts what it claims to measure and
  fails loudly. Assert *feature* availability at runtime too, not just request it.
- `nofile` 65536; `memlock` unlimited if zero-copy is involved.
- `SO_BACKLOG` above the connection count, and `somaxconn` at least as high, or the kernel truncates
  the accept queue and it presents as a stalled ramp rather than an error.
- A **glibc control run** before attributing anything to musl.
- One benchmark on the host at a time. Two of my own runs colliding on the same port and cores
  produced a claimed 292x effect that was entirely contention.

## Where the detail lives

| file | for |
|---|---|
| `ENVIRONMENT.md` | why each rule exists, with the failure that produced it |
| `FINDINGS.md` | the conclusions and their confidence tags |
| `TESTS.md` | one row per test, pointing at `tests/` and the raw data |
| `REPLICATION.md` | the two-machine protocol and the USB key |
| `quic/lib.sh` | the harness itself — extend here rather than reimplementing |
| `~/workspaces/fred/dell-xps-9500-bench-rig` | the host's thermal and clock characterisation |
