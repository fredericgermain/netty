# Q0. QUIC harness design

**Confidence:** SOLID for the mechanism checks below, which were verified on the test host.
**Date:** 2026-08-26
**Question:** not a test. This records the QUIC mode added to the load test, and the decisions that
decide what a QUIC number here means. Read it before reading Q1 onward.

## Configuration

`loadtest/src/main/java/io/netty/loadtest/QuicLoad.java`, reached with `--protocol=quic`. The
phases, the `RAMP` / `STEADY` / `CLIENTCPU` / `SERVERCPU` lines and the `RequestLoop` that drives
them are **shared** with the TCP path (`LoadTest.steady()`, `LoadTest.ramp()`) rather than copied,
so a QUIC table and a TCP table are directly comparable. The wire protocol on a QUIC stream is the
same 4-byte big-endian length prefix.

Dependency: `netty-codec-native-quic` 4.2.18.Final-SNAPSHOT, classifier `linux-x86_64`, which
carries quiche and BoringSSL and pulls `netty-codec-classes-quic` with it.

**Image is `eclipse-temurin:21-jdk`, glibc, not the Alpine image the Part D cells used.** The
released QUIC native artifact does not load on musl, which is the whole subject of
[B](B-quic-musl-fix.md). Running QUIC on glibc keeps the QUIC-versus-TCP question separate from the
musl question. An Alpine QUIC cell would need a `codec-native-quic` built from `quic-musl-compat`
and was not attempted.

Drivers under `benchmark-report/quic/`: `lib.sh` (shared), `quic-vs-tcp.sh`, `quic-transport.sh`,
`quic-rcvbuf.sh`, `quic-streams.sh`, `quic-smoke.sh`, `wait-idle.sh`, `summarise.sh`.

## Result

### Decisions, and why they are what they are

**500 connections, not 10,000.** Every Part D cell used 10,000. A QUIC handshake is a full TLS 1.3
exchange plus quiche's connection setup with no accept queue to absorb a burst, and at 10,000 the
ramp would dominate a 10 second run rather than be reported beside it. 500 is also 500 client UDP
sockets inside a 4-core cpuset. The TCP+TLS comparison cell runs at the same 500, so the two ramps
are the same size of question. **This means no QUIC figure here is comparable to a Part D figure**,
which was taken at 10,000.

**One stream per connection.** The honest analogue of one TCP connection. Multiplexing several
streams on one connection is a different cell, run separately in [Q3](Q3-quic-streams.md).

**The comparison is against TCP+TLS, never against plaintext.** QUIC always encrypts, so a plaintext
TCP cell would make the delta AES rather than transport. The TCP cells use `--tls=openssl`, which is
tcnative/BoringSSL, the same TLS implementation family quiche uses.

**A QUIC server has no accept**, so one UDP socket is one event loop thread for the whole machine.
`--quic-server-sockets=N` binds the port N times with SO_REUSEPORT and lets the kernel's 4-tuple
hash pick the socket. Verified on the host: with `--quic-server-sockets=4`, `ss -ulnp` shows exactly
4 sockets on the port.

**Netty's NIO datagram channel cannot set SO_REUSEPORT.** `NioDatagramChannelConfig` does not know
the option, and `Bootstrap` logs "Unknown channel option" and carries on. So a NIO QUIC server is
structurally capped at one core. The harness aborts on `--quic-server-sockets>1` with NIO rather
than running single-socket under a 4-socket label; verified by running it and reading the
exception. This is why [Q2](Q2-quic-datagram-transport.md) has a separate one-socket block.

**No `QuicCodecDispatcher`.** It exists to re-route a packet the kernel delivered to the wrong
socket, which happens when a client migrates. `activeMigration(false)` is pinned on both peers and
every client socket stays bound for the run, so the kernel's hash over
(saddr, sport, daddr, dport) is a stable router. Leaving the dispatcher out avoids its
cross-event-loop `fireChannelRead`.

**One UDP socket per QUIC connection on the client.** Multiplexing every connection over one socket
would put the whole run on one event loop thread and turn a comparison against N TCP sockets into a
comparison against 1.

**`maxSendUdpPayloadSize` pinned to 1200.** Loopback has a 65536 MTU and would otherwise tempt the
run into a datagram size no internet path carries. 1200 is what a real QUIC deployment sends, so a
64 KB payload is about 55 datagrams each way. This is a large lever that was deliberately not
pulled; a cell at a larger QUIC MTU was not run.

**Flow control windows well above one request in flight**: 16 MB connection, 4 MB stream. A window
near the payload would add a round trip per request and report it as latency. Both are printed in
the `READY` and `CLIENTCFG` lines so a window-bound cell can be identified rather than argued about.

**Aborts, never falls back**, on the same rule as the rest of the harness: `Quic.isAvailable()` is
checked and a missing native library throws rather than proceeding.

### UDP buffers, verified on the host

`SO_RCVBUF` and `SO_SNDBUF` are set explicitly on the datagram channel and read back as the kernel
applied them. On the test host:

| | value |
|---|---|
| `net.core.rmem_max` | 50,000,000 |
| `net.core.rmem_default` | 212,992 |
| `net.core.wmem_max` | **1,048,576** |
| `net.core.wmem_default` | 212,992 |

Requesting 4 MB receive and 1 MB send gives `udpRcvbufActual=8388608` and
`udpSndbufActual=2097152`: Linux returns double the request, half being its own bookkeeping
allowance. `wmem_max` is only 1 MB here, so a send buffer request above that is clamped silently and
the reported actual is the only number worth reading.

`RcvbufErrors` and `InErrors` are read from `/proc/net/snmp` around every cell and reported as
deltas beside the throughput, because an undersized UDP receive buffer is not an error: the kernel
drops the datagram, quiche retransmits over the loss, and the run presents as slow QUIC.

### Clock and heat, recorded per cell

The host is an Intel i5-10300H, a mobile part, `powersave` governor, `intel_pstate`, 800 MHz to
4500 MHz with turbo enabled, and it thermally throttles. It cannot be pinned without root here, so
it is measured: every cell records min/max/mean CPU MHz and peak package temperature sampled twice a
second during the client run (first four ticks discarded, so the figure covers the measured window
rather than an average with startup), plus the **delta** in
`/sys/devices/system/cpu/cpu{0..3}/thermal_throttle/core_throttle_count` across the cell.

The delta is the part that decides whether a cell survives. Cumulative counts over days of uptime
prove only that the host throttles sometimes; a nonzero delta during one cell disqualifies that
cell. On this host the cumulative counts are wildly asymmetric (core0 0, core1 9113, core2 0,
core3 22805), and the **client** cpuset 2,3,6,7 sits on the cores that throttle.

There is a mechanism by which this could bias the transport axis rather than merely add noise:
io_uring parks threads in `iowait`, `intel_pstate` feeds iowait into its boost heuristic, and two
transports can therefore run the same work at different clocks. Interleaving rounds does not average
that away, so the frequency columns are read per cell.

### Operational hardening in the drivers

- Server started with `docker run -d`; the returned container id is compared against the id the name
  resolves to before any log is read. Reading logs by name after a failed `docker run` silently
  reads the previous container, which has already corrupted a run on this host.
- `timeout N docker run` kills the docker CLI, not the container, so every client is force-removed
  before and after on every path and an `EXIT INT TERM` trap covers interrupts.
- Ports scanned in 19990-20050 per cell, skipping 19999 (long-standing orphan) and 20044, checking
  both the UDP and the TCP tables.
- `require_idle` refuses to start a sweep unless no `run-netty` / `echo_bench` / `lt.jar` process
  exists and vmstat idle is 90% or better. The load average on this host reads high and stale even
  when the CPU is free and is deliberately not consulted.

## Raw data

- `loadtest/src/main/java/io/netty/loadtest/QuicLoad.java`
- `benchmark-report/quic/` -- drivers and logs
- `benchmark-report/quic/logs/smoke.log` -- the preflight whose `READY` line carries the socket
  buffer figures quoted above

## Caveats

- Everything here is about the harness, not about QUIC. No performance claim is made in this file.
- The QUIC MTU is fixed at 1200 and was never swept. It is the single largest untested lever.
- GSO (`--quic-gso`) is implemented and aborts cleanly when unsupported, but **was never exercised
  in a measured cell**.
- `--prealloc` is implemented for the QUIC path but every measured cell runs without it, on both
  protocols, so the harness's own per-request allocation is present in both and is not a
  differential.

## Related

- [B](B-quic-musl-fix.md) -- why QUIC runs on glibc here
- [C](C-harness-design.md) -- the TCP harness this extends
- [Q1](Q1-quic-vs-tcp-tls.md) -- the headline comparison
- [Q2](Q2-quic-datagram-transport.md) -- datagram transport sweep
- [Q4](Q4-quic-udp-rcvbuf.md) -- the receive buffer sweep
