# D1. First 10k-connection runs

**Confidence:** SINGLE RUN
**Date:** 2026-08-25, after 16:09 BST (commit `b0a2e1f399`, "Add an open-loop mode" -- `load4.log`
carries the `mode=` labels that commit added)
**Question:** at 10,000 connections, which transport is faster, plaintext and with TLS?

## Configuration

Driver `benchmark-report/scripts/thor-load3.sh`, section B ("saturation throughput, closed loop").

- 10,000 connections, 15 s steady state, 1 KB payload, closed loop
- `--threads=4`, `--backlog=8192`
- Image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`
- TLS rows use `--tls=boringssl` (tcnative/BoringSSL)
- One sample per cell

## Result

From `benchmark-report/logs/load4.log`, section B, verbatim `reqPerSec` values:

| transport | plaintext | TLS (boringssl) |
|---|---|---|
| nio | 150,750 | 89,640 |
| epoll | **166,219** | 95,382 |
| io_uring | 125,895 | **104,256** |

epoll ahead on plaintext (166,219 vs 125,895), io_uring ahead with TLS (104,256 vs 95,382).

**Verified.** All four catalogued figures match `load4.log` exactly. The `nio` row was measured in the
same run and had never been recorded; it is added here because it is the only NIO baseline anywhere
in Part D, and it shows epoll beating NIO by only 10% on plaintext while io_uring loses to NIO.

## Reading

Establishes the shape that drove everything afterwards: epoll wins plaintext, io_uring wins TLS. Both
directions survived later, much better-controlled work -- [D3](D3-interleaved-transport-comparison.md)
for plaintext and [D19](D19-tls-warmup-and-ordering.md) for TLS -- so the direction here was right.

Does **not** establish any magnitude. One sample per cell, no spread, and later interleaved runs show
the TLS cells swinging by more than 40% round to round. Nothing from this run should be quoted as a
figure.

Everything after this run was interleaved *because* of this run.

## Raw data

- `benchmark-report/logs/load4.log`, section B -- the numbers above
- `benchmark-report/logs/load3.log` -- the same script, every cell `SERVER FAILED`, before port
  scanning was added
- `benchmark-report/logs/load.log`, `load2.log` -- two earlier partial attempts. `load.log` has
  `io_uring` failing on a container-name error and the `epoll/jdk` row abandoned mid-ramp with
  `errors=2`. `load2.log` truncates after `epoll/none`.
- `benchmark-report/scripts/thor-load3.sh`, `thor-load.sh`

## Caveats

- **One sample per cell.** No spread, no repeat, no interleaving.
- `TESTS.md` said this ran "on a box whose load average looked high". `load4.log` does **not** record
  a load average, so that cannot be confirmed from the log. The earliest log that does record one is
  `inversion2.log`, where `load1m` ranges 7.34 to 12.91 across five rounds.
- Old SMT-sibling pinning, which [D16](D16-pinning-and-cache-ceiling-64kb.md) later showed works
  against io_uring.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared between client and server.
- 1 KB payload only. The size dependence found in [D10](D10-payload-sweep-and-zero-copy.md) means a
  1 KB result does not generalise.
- Closed loop, so the p50 latencies in this log are queue depth and must not be read as latency.

## Related

- [D2](D2-ring-size-sweep.md) -- the same log's section A
- [D3](D3-interleaved-transport-comparison.md) -- the interleaved replacement for this run
- [D19](D19-tls-warmup-and-ordering.md) -- the TLS direction, properly measured
- [C](C-harness-design.md) -- the harness
