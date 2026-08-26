# Q1. QUIC against TCP+TLS, handshake rate and steady throughput

**Confidence:** SOLID for 1 KB and 8 KB and for every handshake figure.
**DISQUALIFIED for the 64 KB QUIC cell** -- it dropped datagrams in all five rounds. See
[Q1b](Q1b-quic-64kb-tuned-rcvbuf.md).
**Date:** 2026-08-26, ~20:55 BST
**Question:** at equal payload and equal connection count, how does QUIC compare with TCP+TLS on
handshake rate and on steady throughput, and does QUIC show the size-dependent decay that netty's
io_uring and the C io_uring echo server both show?

## Configuration

Driver `benchmark-report/quic/quic-vs-tcp.sh`, raw output `benchmark-report/quic/logs/q1.tsv`.

- **500 connections**, one stream per QUIC connection, 10 s steady state, closed loop
- Payloads 1 KB / 8 KB / 64 KB, 5 rounds, both cells interleaved inside every round and the
  **leading cell alternating** by round parity
- QUIC: `--transport=epoll`, `--quic-server-sockets=4` (SO_REUSEPORT), MTU 1200, CUBIC,
  `--udp-rcvbuf` at its 4 MB default
- TCP: `--transport=epoll --tls=openssl` (tcnative/BoringSSL), `--backlog=8192`
- `--threads=4` both sides, server `--cpuset-cpus=0,1,4,5`, client `2,3,6,7`
- Image `eclipse-temurin:21-jdk` (glibc), `--network=host`, `seccomp=unconfined`,
  `nofile=65536:65536`
- Host verified idle before the sweep; `net.core.rmem_max` 50,000,000, `wmem_max` 1,048,576

See [Q0](Q0-quic-harness-design.md) for why 500 connections, why one stream, and why the comparison
is against TCP+TLS rather than plaintext.

## Result

### Handshake rate, connections/s

| payload group | QUIC median | QUIC spread | TCP+TLS median | TCP+TLS spread | ratio |
|---|---|---|---|---|---|
| 1 KB | 628 | 468 - 647 | 1,263 | 1,211 - 1,300 | **0.50x** |
| 8 KB | 618 | 362 - 629 | 1,248 | 1,224 - 1,265 | **0.50x** |
| 64 KB | 616 | 361 - 634 | 1,277 | 1,258 - 1,309 | **0.48x** |

**A QUIC handshake costs about twice a TCP+TLS one, and that is robust.** Three independent groups
agree on 0.48-0.50x, the ranges do not overlap in any group, and TCP+TLS leads in all fifteen
rounds. The payload grouping is incidental -- the ramp happens before any payload is sent -- so the
three rows are three replications of one measurement, which is why the agreement is worth quoting.

QUIC's spread is wide (38-76%) and TCP's is not (3-7%). The wide rounds are the ones where the ramp
took 1,380 ms instead of ~790 ms; they cluster in round 2, which was slow across every cell.

### Steady throughput, requests/s

| payload | QUIC median | QUIC spread | TCP+TLS median | TCP+TLS spread | ratio | verdict |
|---|---|---|---|---|---|---|
| 1 KB | 52,900 | 43,775 - 55,970 | 106,274 | 103,578 - 107,053 | **0.50x** | separated |
| 8 KB | 5,129 | 3,473 - 5,518 | 73,978 | 52,143 - 75,466 | **0.07x** | separated |
| 64 KB | 549 | 379 - 606 | 17,185 | 13,142 - 17,950 | 0.03x | **QUIC cell disqualified** |

The ranges do not overlap at any payload, and the gaps are far larger than the spreads.

### The decay is real, and it is not the same shape as io_uring's

`req/s` is not comparable across payloads, so read it as bandwidth:

| payload | QUIC MB/s | TCP+TLS MB/s |
|---|---|---|
| 1 KB | 54 | 109 |
| 8 KB | 42 | 606 |
| 64 KB | 36 (with loss) | 1,126 |

**TCP+TLS scales with payload. QUIC does not: it sits between 36 and 54 MB/s at every size.** The
io_uring deficit that Part D found is a ratio that widens while *both* transports get faster
([D10](D10-payload-sweep-and-zero-copy.md): 87%, 75%, 47%, 41% of epoll). This is a different shape.
QUIC has a throughput ceiling that payload does not move, so the ratio collapses simply because the
number it is divided by keeps growing.

That points at a per-datagram cost rather than a per-byte one, and the datagram count is fixed by
`maxSendUdpPayloadSize`, which is pinned at 1200 here. Estimated datagrams per second, taking
`ceil(payload / 1200)` datagrams each way:

| payload | datagrams per request | datagrams/s |
|---|---|---|
| 1 KB | 2 | ~106,000 |
| 8 KB | 14 | ~72,000 |
| 64 KB | 110 | ~60,000 |

Same order of magnitude across a 64x change in payload, against a 96x change in req/s. The smoke
run corroborates the model directly: `/proc/net/snmp` counted 1,146,533 datagrams for 570,154
requests at 1 KB, which is 2.01 per request.

### Clock, heat and throttling

No cell was thermally throttled except two: **round 5 TCP at 8 KB and round 5 TCP at 64 KB each
recorded a throttle delta of 4 on core 3**. Both still produced ordinary numbers (75,466 and 17,272
req/s, both inside their cell's range), so neither is excluded, but they are the only two cells in
this sweep whose figures carry that caveat.

Package temperature ran 70 C to 84 C, rising through the sweep. Mean CPU frequency was 2,649 to
2,892 MHz per cell with per-sample excursions from the 800 MHz floor to the 4,500 MHz turbo ceiling
in nearly every cell. **The mean frequency does not separate the two protocols** -- QUIC cells
averaged 2,688-2,892 MHz and TCP cells 2,649-2,804 MHz, overlapping -- so the io_uring/iowait
governor-bias mechanism does not appear on this axis here. It was not tested on the transport axis;
that is [Q2](Q2-quic-datagram-transport.md).

Round 2 was globally slow: every cell in it, both protocols, came in at or near its own minimum.
This is why the interleaving matters and why the per-round spreads are reported.

## Reading

Establishes that **a QUIC handshake costs about 2x a TCP+TLS handshake** on this host at 500
connections. Fifteen rounds, three independent groups, no overlap.

Establishes that **QUIC's steady throughput is about half TCP+TLS's at 1 KB** and that the deficit
grows enormously with payload.

Establishes that **QUIC does not show the same size-dependent decay as io_uring**. The shape is
different: io_uring's ratio widened while both transports accelerated, whereas QUIC's absolute
bandwidth is flat and only the ratio moves. Whatever produces netty's io_uring size cliff, this is
not another instance of it.

Does **not** establish the 64 KB QUIC number. Every round dropped 13,642 to 26,296 datagrams to
`RcvbufErrors`, so that cell measured packet loss and quiche's retransmission of it.
[Q1b](Q1b-quic-64kb-tuned-rcvbuf.md) re-runs it with a 16 MB receive buffer.

Does **not** establish that the ceiling is caused by the 1200-byte QUIC MTU. The datagram-rate
arithmetic is consistent with it and nothing here contradicts it, but the MTU was never swept, and
that is the single largest untested lever in this whole set.

Does **not** generalise to 10,000 connections. Every Part D figure was taken there and none of these
are comparable to them.

## Raw data

- `benchmark-report/quic/logs/q1.tsv` -- all thirty rows, verbatim
- `benchmark-report/quic/logs/smoke.log` -- the preflight, including the datagram counts quoted above
- `benchmark-report/quic/quic-vs-tcp.sh`, `benchmark-report/quic/lib.sh`
- `benchmark-report/quic/summarise.sh` -- produced every median and spread in this file

## Caveats

- **500 connections, not 10,000.** Nothing here is comparable to a Part D number.
- **QUIC MTU pinned at 1200 and never swept.** See above.
- Closed loop, so p50 is queue depth and not service time. The percentile columns are recorded in
  the TSV for completeness and no claim is made from them.
- Spreads are large in absolute terms (up to 60% within a cell). The conclusions survive only
  because the gaps between cells are much larger still.
- The two round-5 TCP cells with a nonzero throttle delta are named above.
- Loopback, one host, 4 physical cores shared between client and server, kernel 6.8.
- No `--prealloc` on either protocol, so the harness's own per-request allocation is present in
  both cells and is not a differential. [D21](D21-stacked-remediation.md) shows it is not neutral in
  absolute terms.

## Related

- [Q0](Q0-quic-harness-design.md) -- the harness and every design decision behind these numbers
- [Q1b](Q1b-quic-64kb-tuned-rcvbuf.md) -- the 64 KB cell re-run with a receive buffer that does not drop
- [Q2](Q2-quic-datagram-transport.md) -- which datagram transport QUIC does best on
- [Q4](Q4-quic-udp-rcvbuf.md) -- what the receive buffer is worth
- [D10](D10-payload-sweep-and-zero-copy.md) -- the io_uring size curve this is compared against
