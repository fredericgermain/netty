# Q2. Why netty QUIC is ~17% slower on musl than on glibc

**Confidence:** SOLID. Root cause identified and confirmed by an intervention that removes it, with
two independent replacements agreeing. Contains two hypotheses I asserted and then had to withdraw.
**Date:** 2026-08-27
**Question:** netty QUIC runs about 17% slower on Alpine than on Debian with the same jar and the
same hardware. Where does the difference go, and is any of it netty's?

## Answer

**musl's `mallocng` allocator serialises on a shared lock, and quiche's native allocation hammers
it.** Nothing in netty and nothing in the codec-native-quic musl fix is implicated.

`LD_PRELOAD=/usr/lib/libjemalloc.so.2` removes almost all of it:

| config | ctx switches / 5 s | req/s | vs glibc |
|---|---|---|---|
| musl, `mallocng` (default) | 29,883 | 53,737 | **-17.3%** |
| musl + jemalloc | 1,103 | **64,149** | **-1.3%** |
| musl + mimalloc | 1,465 | 60,644 | -6.7% |
| glibc (control) | 851 | 64,997 | -- |

A 27x reduction in context switches, and the throughput gap goes from 17.3% to 1.3%. Two unrelated
allocators both fix it, so this is not a property of one replacement.

## Configuration

Host `thor`, 4 physical cores, clock capped at `intel_pstate` `max_perf_pct=62` for a stable
~2800 MHz with zero thermal throttling. Server pinned to physical cores 0,1,4,5 and client to
2,3,6,7. QUIC, 500 connections, one stream each, 1 KB payload, 4 event loop threads. Server side
measured. Images `eclipse-temurin:21-jdk-alpine` (plus `musl-dbg`, jemalloc, mimalloc) against
`eclipse-temurin:21-jdk`, same `loadtest.jar` built from the published
`4.2.18.Final-20260827.083944-1`.

## The chain, each step measured

**1. A tight, parameterised loop.** The original repro was a two-container load test taking about a
minute per cell. It was replaced with `csloop.sh`, which runs one workload on musl and on glibc,
reports the context-switch ratio, and prints RED or GREEN against a threshold. Parameterising over
the workload is what made the rest of this cheap: minimisation became a matter of changing one
argument.

**2. Minimisation. The symptom is QUIC-specific.**

| workload | musl | glibc | ratio | |
|---|---|---|---|---|
| idle QUIC server, no load | 206 | 211 | 0.98 | GREEN |
| pure CPU, 4 threads | 570 | 595 | 0.96 | GREEN |
| raw UDP echo on loopback, 4 threads | 1,100,791 | 1,082,131 | 1.02 | GREEN |
| netty TCP plaintext, 500 conns | 14,128 | 14,145 | 1.00 | GREEN |
| netty TCP + TLS, 500 conns | 168 | 173 | 0.97 | GREEN |
| **netty QUIC, 500 conns** | **32,499** | **2,694** | **12.06** | **RED** |

Not the JVM, not musl generally, not scheduling, not datagram syscalls, not netty's transport, not
TLS through BoringSSL. Only the path containing **quiche**.

The TCP+TLS row was checked before being believed: 168 switches is close to an idle server's 206, so
the cell was re-run with output captured. It is genuine, 500 connections at 50,844 req/s with zero
errors. TLS keeps the event loops CPU-busy so they rarely park, while plaintext is I/O-bound and
parks more, which is why the encrypted row switches *less*.

**3. Symbols.** Alpine's `musl-dbg` package resolves what was previously a single opaque frame,
`/lib/ld-musl-x86_64.so.1`, holding the largest single per-request cost in the profile. musl links
allocator, string routines, pthread and the dynamic linker into one stripped image, so unlike glibc
there is nothing to attribute without it. With symbols the top musl frames are `__lock` 2.17%,
`memcpy` 1.85%, `__libc_malloc_impl` 1.77%, `alloc_slot` 1.25%, `get_meta` 1.14% -- `mallocng`
internals.

**4. Futex callers.** A CPU profiler cannot see a parked thread, so the futex entry tracepoint was
traced with call graphs instead. musl: `__unlock` 67%, `__lock` 32%. glibc:
`pthread_cond_timedwait` -> `PlatformMonitor::wait` -> `Monitor::wait_without_safepoint_check`,
which is ordinary JVM monitor parking.

**5. The intervention.** Replacing the allocator collapses both the switches and the gap, as above.

## Two hypotheses asserted and withdrawn

Both were stated confidently before the falsifying test was run, and both were wrong. They are kept
because the pattern is the finding.

**"Allocation is ruled out."** `--prealloc` cut per-request allocation from ~886 to ~637 B and left
musl's context switches flat (34,150 -> 34,583), which looked decisive. It was not:
`--prealloc` reduces netty's **Java-side** allocation only. quiche is Rust and allocates straight
through musl, untouched by that flag. One side was tested and the whole hypothesis declared dead.

**"Four threads contending on the allocator lock."** Also wrong as stated. The gap persists
single-threaded, 2,925 against 330, and one thread cannot contend with itself. The mechanism is the
cost of `mallocng`'s locking on every allocation, not contention between event loops. The
`__lock` / `alloc_slot` / `get_meta` frames were real, but reading a mechanism off a frame list is
not the same as testing it.

The `LD_PRELOAD` test should have come first. It is cheap, decisive, and doubles as the remedy.

## Reading

**What this establishes.** The musl QUIC deficit is an allocator property of the platform, not a
defect in netty or in the musl loadability fix. Any JVM application doing heavy **native**
allocation on musl should be expected to hit it; QUIC surfaces it because quiche allocates hard in
Rust on every packet.

It also explains a result recorded earlier that looked inconsistent with this one: `boringssl-static`
showed **no** libc effect on TLS handshakes ([A4](A4-libc-effect-by-tcnative-flavour.md)). BoringSSL
allocates far less per operation than quiche does, so it never reaches the lock hard enough to
matter.

**What this does not establish.** The exact call sites inside quiche were never named: musl is built
without frame pointers, so futex stacks bottom out at raw addresses above `__unlock`. Naming them
needs `perf --call-graph dwarf` or a `bpftrace` uprobe on `__lock`. Not needed for the conclusion,
since the intervention confirms the mechanism, but it would be needed to reduce the allocation rate
rather than work around the allocator.

mimalloc recovering less than jemalloc (-6.7% against -1.3%) is unexplained and was measured once.

**Practical remedy for Alpine deployments**, one environment variable:

    apk add jemalloc
    LD_PRELOAD=/usr/lib/libjemalloc.so.2

## Raw data

On `thor`: `/tmp/csloop.sh` (the loop), `/tmp/probes/{Busy,Udp}.java`, `/tmp/quic-deep.sh`,
`/tmp/quic-futex.sh`, `/tmp/alloc-test.sh`, and the images `alpine-jdk-musldbg` and
`alpine-jdk-musl-alloc` (Dockerfiles at `/tmp/Dockerfile.musldbg`, `/tmp/Dockerfile.muslalloc`).

**These live only on the test host and are not committed.** Given that scripts have already been
lost to a reboot once in this work, they should be copied into `benchmark-report/scripts/` if this
result is to survive.

## Related

- [Q1](Q1-quic-vs-tcp-tls.md) -- QUIC against TCP+TLS, where the bandwidth ceiling was found
- [A4](A4-libc-effect-by-tcnative-flavour.md) -- the TLS handshake result this explains
