# D2. Ring size sweep

**Confidence:** SOLID
**Date:** 2026-08-25, between 18:58 and 19:15 BST (commits `7c819dab8e` "Size the io_uring ring to
the workload" and `45a06b50bf` "Correct the io_uring ring-size claim: it was not the ring")
**Question:** is io_uring's deficit caused by a completion queue that is too small?

## Configuration

Driver `benchmark-report/scripts/thor-load3.sh`, section A.

- 10,000 connections, 15 s steady state, 1 KB payload, closed loop, plaintext
- Ring sizes 4096 (netty's default), 16384, 32768 via `--ring-size`
- `--threads=4`, `--backlog=8192`, image `eclipse-temurin:21-jdk-alpine`
- **Old (SMT-sibling) pinning**: server `0-3`, client `4-7`
- One sample per ring size

## Result

| ring size | req/s |
|---|---|
| 4096 (netty default) | 127,590 |
| 16384 | 127,014 |
| 32768 | 125,817 |

No difference. Verbatim from `benchmark-report/logs/load4.log`:

```
io_uring ring=4096 (netty default) ... reqPerSec=127590 ...
io_uring ring=16384                ... reqPerSec=127014 ...
io_uring ring=32768                ... reqPerSec=125817 ...
```

**Upgraded from RECALLED to SOLID.** All three values verified against
`benchmark-report/logs/load4.log`, section A.

### WITHDRAWN

This sweep retracted a claimed **292x effect**. The original observation -- 578 req/s against epoll's
168,789, with a `CompletionQueue overflow detected, consider increasing size: 4096` warning -- was
caused by two of my own runs colliding on the same port and cores. The overflow warning was a symptom
of the contention, not its cause. Correction committed at `45a06b50bf`.

**This retraction stands. Do not soften it.** A 292x number was published internally on the strength
of a warning message and one run.

## Reading

Establishes that ring size is not the mechanism, cleanly: three sizes spanning 8x, all within 1.4% of
each other, and the largest ring is the *slowest* of the three. Nothing here is a ring-capacity
effect.

Also establishes the more useful methodological point: the failure that produced the 292x claim did
not look like a failure. It looked like a very slow run with a helpful diagnostic attached.

Does **not** establish anything about ring size at other payloads or connection counts. 1 KB, 10k
connections, one sample each.

## Raw data

- `benchmark-report/logs/load4.log`, section A -- the three verified figures
- `benchmark-report/logs/load2.log` -- contains `epoll/none ... reqPerSec=168789`, the epoll figure
  the withdrawn 292x claim was measured against
- `benchmark-report/scripts/thor-load3.sh`
- **The 578 req/s run is not recoverable from any committed log.** `load2.log` ends immediately after
  the line `io_uring/none` with no output at all, so neither the 578 figure nor the
  `CompletionQueue overflow detected` warning text survives in this branch. The withdrawal is
  documented; the thing withdrawn is not.

## Caveats

- One sample per ring size. The conclusion is safe only because the three agree so closely.
- Old SMT-sibling pinning.
- 1 KB payload, loopback, queue depth 1, kernel 6.8, 4 physical cores.
- Closed loop.
- A ring-size effect could still exist at a workload with deeper queueing. This tests one point.

## Related

- [D1](D1-first-10k-connection-runs.md) -- the same log's section B
- [D7](D7-buffer-rings-at-1kb.md) -- the *provided buffer* ring, a different mechanism entirely
- [D17](D17-mechanism-discriminator.md) -- the sweep that did find the mechanism
