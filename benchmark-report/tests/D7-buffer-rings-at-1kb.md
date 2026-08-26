# D7. Buffer rings and multishot recv at 1 KB

**Confidence:** SOLID
**Date:** 2026-08-26, around 06:19 BST (commit `c47f10147c`, "Sweep buffer rings and multishot recv:
no effect on the plaintext gap")
**Question:** does configuring a provided buffer ring -- which is also what arms multishot recv --
close the plaintext gap?

## Configuration

Driver `benchmark-report/scripts/thor-bufring.sh`.

- 10,000 connections, 10 s, 1 KB payload, plaintext, closed loop
- 5 rounds, four cells interleaved per round
- `--buffer-ring=<entries>` on both server and client; entries 0 (none), 1024, 4096
- `--threads=4`, `--backlog=8192`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `--cpuset-cpus=0-3`, client `--cpuset-cpus=4-7`
- Jar `loadtest-br.jar`

## Result

| cell | rounds | median |
|---|---|---|
| epoll | 137,726 - 166,466 | 159,512 |
| io_uring, no buffer ring | 101,105 - 119,759 | 117,079 |
| io_uring + ring 1024 | 110,861 - 120,091 | 116,356 |
| io_uring + ring 4096 | 107,439 - 124,705 | 115,023 |

No effect.

Discovered here: netty arms `IORING_RECV_MULTISHOT` only inside `scheduleReadProviderBuffer()`,
reached only with a buffer ring configured, and **none is configured by default**. Also found that
`IoUringBufferRingConfig.builder()` throws unless `batchSize()` is set -- the builder initialises it
to -1 and `build()` validates it into 1..1024, so it throws where every other optional field has a
working default.

## Reading

Establishes that provided buffer rings do nothing at 1 KB, across three ring sizes and five
interleaved rounds. The three io_uring medians sit within 1.8% of each other while the spread within
each cell is 12-16%, so the sweep has no resolving power below about 10% -- but it comfortably
excludes an effect large enough to matter against a 36% gap.

Establishes two netty source findings that are independent of any measurement, both verified by
reading the code: multishot recv is silently inert by default, and the buffer ring builder has a
missing default.

Does **not** establish that buffer rings never help. The question was asked at the wrong payload
size, which [D11](D11-buffer-rings-at-64kb.md) went back and fixed.

Does **not** verify that the ring actually engaged. There is no assertion in the harness that the
configured ring was accepted and used. [D11](D11-buffer-rings-at-64kb.md) later raised exactly this
doubt about its own +5%, and it applies retroactively here: a ring that never engaged and a ring that
engaged without helping produce the same numbers.

## Raw data

- `benchmark-report/scripts/thor-bufring.sh` -- the driver, confirming the four cells and the ring
  sizes
- **No run log is committed.** There is no `bufring.log` in `benchmark-report/logs/`. The round
  spreads and medians above are carried forward from the catalogue and **could not be verified
  against raw output**.
- The netty source findings are verifiable in this branch:
  `transport-classes-io_uring/src/main/java/io/netty/channel/uring/`.

## Caveats

- **Raw data not committed.**
- 1 KB payload only. This is the wrong size for the question, established afterwards.
- No `isUsable()` assertion, so "ring configured" is not the same as "ring engaged".
- Old SMT-sibling pinning; loopback; queue depth 1; kernel 6.8; 4 physical cores shared.
- Ring applied to both client and server simultaneously, so a one-sided effect could cancel.
- Only two non-zero ring sizes, both with default buffer size.

## Related

- [D11](D11-buffer-rings-at-64kb.md) -- the same question at 64 KB, where a small effect appears
- [D2](D2-ring-size-sweep.md) -- the submission/completion ring, a different thing entirely
- [D17](D17-mechanism-discriminator.md) -- why a buffer ring *should* matter: it deletes the
  POLL_ADD round trip
