# D17. Mechanism discriminator

**Confidence:** SOLID
**Date:** 2026-08-26, around 09:51 BST (commit `28e0aed38b`, "Discriminate the mechanism: reads per
message, not writes or the allocator"; script committed at `94880d4a95`, 07:41)
**Question:** three hypotheses remain for the size cliff -- the missing write spin loop, the receive
footprint, and per-operation cost. Each predicts a different lever. Which lever moves?

**The single most important run in this work.**

## Configuration

Driver `loadtest/scripts/thor-mech.sh`, invoked as `thor-mech.sh 65536 2000 5`. Jar
`loadtest-pin.jar`, image `eclipse-temurin:21-jdk-alpine`.

- **64 KB payload, 2,000 connections, 10 s**, plaintext, closed loop
- **5 rounds, eight cells interleaved per round**
- **Corrected whole-core pinning throughout**: server `--cpuset-cpus=0,1,4,5`, client
  `--cpuset-cpus=2,3,6,7`
- `--threads=4`, `--backlog=8192`, `--tls=none`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`, `memlock=-1`
- `--sndbuf` and `--rcvbuf-max` applied to **both** server and client

Why these values, from the script header: thor autotunes `tcp_wmem` from 16 KB up to 4 MB. Setting
`SO_SNDBUF` pins it, the kernel doubles the requested value, and `wmem_max` of 1 MB caps the request,
so `--sndbuf=65536` and `--sndbuf=1048576` give fixed 128 KB and 2 MB send buffers.

## Result

| cell | median |
|---|---|
| epoll default | 40,630 |
| io_uring default | 17,257 |
| io_uring `SO_SNDBUF=64K` | 17,089 |
| io_uring `SO_SNDBUF=1M` | 17,502 |
| io_uring `--rcvbuf-max=16K` | 13,586 |
| io_uring `--rcvbuf-max=512K` | 23,458 |

Send buffer moves nothing (rejects the write-spin-loop hypothesis). Receive buffer moves throughput
**73%** monotonically -- 13,586 to 23,458 -- tracking reads per message.

**The two epoll `SO_SNDBUF` control cells were run and were never recorded in the catalogue.** They
matter, because they are what makes the send-buffer rejection a controlled result rather than a null
result:

| cell | median |
|---|---|
| epoll `SO_SNDBUF=64K` | 43,163 |
| epoll `SO_SNDBUF=1M` | 40,598 |

epoll moves +6.2% and -0.1%; io_uring moves -1.0% and +1.4%. Neither transport responds to the send
buffer, in either direction, across a 16x range.

Per-round, verbatim from `benchmark-report/logs/mech64.log`:

```
round  ep-def     ur-def     ep-s64K    ur-s64K    ep-s1M     ur-s1M     ur-r16K    ur-r512K
1      41446      17257      43709      18259      41121      17059      13406      20227
2      38081      16282      43163      16929      40598      17502      12537      23458
3      40630      17892      44770      17884      44156      17830      13759      23827
4      41818      17314      38620      16528      37701      17053      13948      24003
5      38641      16666      38347      17089      38178      17629      13586      23430
```

**Verified against `benchmark-report/logs/mech64.log`.** All six catalogued medians match exactly as
medians of the five rounds.

## Reading

Establishes the mechanism by discrimination rather than by assertion, which is why this run is worth
more than the profiles. Three hypotheses, three different predicted levers, one sweep:

- **Missing write spin loop.** Netty's epoll transport runs `do { doWriteMultiple } while
  (writeSpinCount > 0)`, up to 16 back-to-back writes per event-loop turn; the io_uring transport
  submits one send op and never reads `getWriteSpinCount()` at all. Partial writes scale with message
  size, so it predicted the widening curve precisely. **Rejected**: a 16x larger send buffer moves
  nothing on either transport.
- **Receive footprint.** Predicted that *capping* the receive buffer would help io_uring by shrinking
  the committed footprint. **Rejected**: capping at 16K makes it 21% *worse*.
- **Per-read cost.** Predicted throughput inversely ordered with read count. **Survives**, and it is
  the only one that does.

The read-count arithmetic: a 64 KB payload plus its 4-byte header needs roughly 5 reads at a 16K
buffer, 2 at 64K, 1 at 512K. Throughput is inversely ordered with the read count in every cell, and
monotonically.

And io_uring pays about **double per read**: with no provided buffer ring configured
`isPollInFirst()` returns true (`AbstractIoUringStreamChannel.java:798-801`) and every read is
POLL_ADD *then* RECV -- two submissions and two completions -- where epoll does one `read()` on a
shared `epoll_wait` wakeup. A per-read penalty multiplied by a read count that rises with payload is
exactly a deficit that widens with message size.

Netty's `AdaptiveRecvByteBufAllocator` caps at 64 KB by default, which is why reads per message grow
with payload at all.

Raising the receive buffer recovers about a third of the gap: 42.5% of epoll at default (17,257 /
40,630) to 57.7% at 512K (23,458 / 40,630), with one channel option.

Does **not** prove the POLL_ADD+RECV pairing is what costs the double. That is a source reading of
`isPollInFirst()`, consistent with the data, not measured. A working provided buffer ring would test
it directly by deleting the POLL_ADD -- and [D11](D11-buffer-rings-at-64kb.md) suggests the ring may
never have engaged.

Does **not** close the gap. 57.7% is better than 42.5% and it is still a long way from parity.
[D21](D21-stacked-remediation.md) goes further.

## Raw data

- `benchmark-report/logs/mech64.log` -- five rounds, eight cells, per-round detail with server pool
  ranges and client CPU counters
- `loadtest/scripts/thor-mech.sh` -- the driver, with both hypotheses stated in the header before the
  run

**The driver has been extended since `mech64.log` was produced**, and the extension names an open
question about this very result. It now carries an `EXTRA` variable whose stated purpose is to re-run
the whole discriminator with `--prealloc`, described in the script header as "the only way to tell
whether the read-count conclusion below was a property of netty or of a load generator that memset
its payload on every request". It also adds a `CLIMODE` guard that aborts a cell if `--prealloc` was
requested and the client did not report `prealloc=true`, and raises the client timeout from 150 s to
200 s.

`mech64.log` predates all of that and was produced without `--prealloc`. **The `--prealloc` control
has not been run**, or at least its output is not committed.

Two further scripts exist in the working tree, uncommitted and unrun as of 2026-08-26:
`loadtest/scripts/thor-prealloc.sh` and `loadtest/scripts/thor-allocprof.sh`. The first states the
challenge to this test explicitly -- "if the gap closes, the memory story was primary after all and
the reads-per-message conclusion is wrong" -- and decomposes `--prealloc` into three separable
changes (`noalloc`, `+warm`, `+fixed`) so that which one moves the number is measured rather than
assumed. **Watch for its results before publishing this test.**

## Caveats

- 64 KB and 2,000 connections only. The mechanism is inferred to generalise across the payload sweep;
  it was not re-run at 1 KB or 256 KB in this form. [D21](D21-stacked-remediation.md) does cover
  256 KB for the 512K cell.
- `--rcvbuf-max` is applied to both client and server, so a one-sided effect cannot be separated.
- The read-count arithmetic (5 / 2 / 1) is arithmetic, not a measurement. Reads per message were
  never counted directly, for instance with an eBPF probe on `recvmsg`.
- **The load generator's own payload construction is an uncontrolled variable.**
  [D13](D13-profiling-at-256kb.md) established by stack walk that the client zeroes a fresh payload
  buffer on every request (`RequestLoop.sendClosed -> writeZero`), work that belongs to the harness
  and not to netty. `--rcvbuf-max` changes how much of that buffer is touched per read, so a cell's
  throughput could in principle move for a reason that has nothing to do with the transport. The
  `--prealloc` control that would settle this exists in the driver and has not been run. Until it
  has, the read-count conclusion is well supported but not isolated from the instrument.
- The 512K cell's footprint cost is real and not accounted for here: its server pool ranges 16-224 MB
  across rounds, against the default cell's 16-216 MB. Faster and not cheaper.
- `ur-r512K` round 1 is 20,227, well below the other four rounds (23,430 to 24,003). The median is
  unaffected; a mean would be.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared, corrected pinning still gives only
  two physical cores per side.
- The `isPollInFirst()` line reference is against this branch's netty 4.2.18-SNAPSHOT and will drift.

## Related

- [D10](D10-payload-sweep-and-zero-copy.md) -- the curve this explains
- [D11](D11-buffer-rings-at-64kb.md) -- the buffer ring that should delete the POLL_ADD
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the cache ceiling, a different lever
- [D21](D21-stacked-remediation.md) -- the receive buffer combined with the cache ceiling
- [D18](D18-glibc-control.md) -- the same cell on glibc
