# D21. Stacked remediation: receive buffer plus cache ceiling

**Confidence:** SOLID
**Date:** 2026-08-26, around 07:51 BST (commit `ee4d2351a2`, "Add stacked-remediation and glibc-control
sweeps")
**Question:** the 512 KB receive buffer and the raised cache ceiling each helped io_uring on their
own. Are they additive, and does applying both to epoll as well leave the ratio where it started?

**This test was not in the catalogue, and its logs were misdescribed.** `TESTS.md` listed
`stack64.log` and `stack256.log` as "profile stack extracts", never read, and named them again as an
open item. They are not stack extracts. They are **five-round throughput sweeps** produced by
`loadtest/scripts/thor-stack.sh`, and they contain the largest single improvement to io_uring
measured anywhere in this branch.

## Configuration

Driver `loadtest/scripts/thor-stack.sh`, run twice: `thor-stack.sh 65536 2000 5 stack` and
`thor-stack.sh 262144 500 5 stack256`. Jar `loadtest-pin.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- **64 KB / 2,000 connections** and **256 KB / 500 connections**, 10 s, plaintext, closed loop
- **5 rounds, five cells interleaved per round**
- **Corrected whole-core pinning**: server `--cpuset-cpus=0,1,4,5`, client `--cpuset-cpus=2,3,6,7`
- `--threads=4`, `--backlog=8192`, `--tls=none`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`, `memlock=-1`

The five cells:

| cell | program args | JVM flags |
|---|---|---|
| `ep-def` | epoll, none | none |
| `ur-def` | io_uring, none | none |
| `ur-r512` | io_uring, `--rcvbuf-max=524288` | none |
| `ep-stack` | epoll, `--rcvbuf-max=524288` | `-Dio.netty.allocator.maxCachedBufferCapacity=1048576` |
| `ur-stack` | io_uring, `--rcvbuf-max=524288` | `-Dio.netty.allocator.maxCachedBufferCapacity=1048576` |

The ceiling is 1 MB rather than the 256 KB used in [D16](D16-pinning-and-cache-ceiling-64kb.md),
because a 512 KB receive buffer would bypass a 256 KB cache entirely. Both flags are applied to epoll
too, which is the control that matters: epoll's default adaptive receive ceiling is the same 64 KB,
so if bigger reads help it equally then the ratio goes nowhere and the "remediation" is just a tuning
tip for both transports. The `ur-r512` cell decomposes the stack, saying whether the two levers are
additive or the same effect counted twice.

## Result

### 64 KB, 2,000 connections

Medians of five rounds, from `benchmark-report/logs/stack64.log`:

| cell | median | as % of `ep-def` |
|---|---|---|
| `ep-def` | 41,310 | |
| `ur-def` | 17,850 | 43.2% |
| `ur-r512` | 23,561 | 57.0% |
| `ep-stack` | 39,816 | |
| `ur-stack` | **28,687** | **69.4%** |

Per-round, verbatim:

```
round  ep-def     ur-def     ur-r512    ep-stack   ur-stack
1      41815      18701      20666      39816      28687
2      37135      17538      23941      39701      28747
3      41310      17850      23653      41147      28775
4      41789      17931      23561      40016      28176
5      35904      17613      23555      38821      27595
```

### 256 KB, 500 connections

Medians of five rounds, from `benchmark-report/logs/stack256.log`:

| cell | median | as % of `ep-def` |
|---|---|---|
| `ep-def` | 8,979 | |
| `ur-def` | 4,001 | 44.6% |
| `ur-r512` | 5,105 | 56.9% |
| `ep-stack` | 6,748 | |
| `ur-stack` | **5,706** | **63.5%** |

Per-round, verbatim:

```
round  ep-def     ur-def     ur-r512    ep-stack   ur-stack
1      8572       4122       4980       6761       5763
2      8979       3996       5355       6494       5543
3      9157       4001       5122       6748       5742
4      8512       4032       4775       6776       5706
5      9082       3952       5105       6730       5572
```

## Reading

**This is the largest remediation measured in the branch, and nothing currently records it.** At
64 KB, io_uring goes from 43.2% of epoll to 69.4% -- recovering roughly half the gap -- with one
channel option and one JVM flag, no code change.

**The two levers are close to additive.** The receive buffer alone is +32% (17,850 to 23,561). The
cache ceiling alone was +14.9% at 64 KB in [D16](D16-pinning-and-cache-ceiling-64kb.md). Multiplied,
that predicts +52%; measured together it is **+61%** (17,850 to 28,687). They are not the same effect
counted twice, which was the specific thing the `ur-r512` decomposition cell was there to rule out.

**The epoll control does its job and is the reason the result counts.** Applying both flags to epoll
moves it from 41,310 to 39,816, that is -3.6%. Bigger reads do *not* help epoll equally, so the
improvement is genuinely io_uring's, and the ratio moves because the numerator rose rather than
because the denominator fell.

The mechanism is exactly [D17](D17-mechanism-discriminator.md)'s: io_uring pays roughly double per
read, so reducing a 64 KB message from two reads to one is worth more to it than to epoll. The cache
ceiling then keeps the now-larger buffers out of the arena, which is what
[D14](D14-pooled-memory-measurement.md) and [D20](D20-pinning-and-cache-ceiling-256kb.md) showed
mattered. Two mechanisms, two levers, and they compose.

**At 256 KB the story is weaker and must be reported as such.** io_uring does improve, 4,001 to
5,706, +43%. But epoll *drops* 25% (8,979 to 6,748) under the same flags, the same epoll regression
[D20](D20-pinning-and-cache-ceiling-256kb.md) found with a 256 KB ceiling. So `ur-stack` reaching
84.6% of `ep-stack` is arithmetic, not a result. Against the best epoll configuration -- which is
still the default, 8,979 -- io_uring reaches **63.5%**.

The `ur-r512` cell also replicates [D17](D17-mechanism-discriminator.md) independently: 23,561 here
against 23,458 in `mech64.log`, two separate five-round sweeps on separate runs, 0.4% apart. That is
the tightest cross-run agreement anywhere in Part D and it is worth citing.

Does **not** close the gap. 69.4% at 64 KB is a large improvement and io_uring is still losing by
44%.

Does **not** come for free. `ur-stack`'s server pool ranges 80-332 MB across rounds at 64 KB, against
`ur-def`'s 16-220 MB -- a much larger footprint for the throughput. At 256 KB `ur-stack` sits at
304-384 MB against `ur-def`'s 32-136 MB. **This is a memory-for-throughput trade and it should never
be quoted without the footprint.**

Does **not** separate server from client. Both flags are applied to both sides.

## Raw data

- `benchmark-report/logs/stack64.log` -- five rounds, five cells, with server pool ranges and client
  CPU counters. **Previously misdescribed as a profile stack extract and flagged as never read.**
- `benchmark-report/logs/stack256.log` -- same at 256 KB. Same misdescription.
- `loadtest/scripts/thor-stack.sh` -- the driver, with the additivity question stated in the header
  before the run
- `benchmark-report/scripts/stacks.sh` -- unrelated despite the name; it post-processes
  [D13](D13-profiling-at-256kb.md)'s collapsed stacks and reads `/home/fred/tls-matrix/bigprof/`.
  The name collision is almost certainly what caused the misdescription.

## Caveats

- Two payload sizes only, each with its own connection count. Payload and connections are confounded
  between the two runs.
- Both flags applied to both client and server. A server-only deployment recommendation is not
  supported by this data.
- **Memory cost is large and is not optional.** See above.
- One receive-buffer value (512 KB) and one ceiling (1 MB). No sweep of either.
- The `ep-def` cell at 64 KB spans 35,904 to 41,815 (16%), so the 43.2% and 69.4% ratios carry that
  uncertainty in their denominator. The `ur-stack` cell itself is tight (27,595 to 28,775, 4.3%).
- `ur-r512` round 1 at 64 KB is 20,666, well below the other four (23,555 to 23,941); the median is
  unaffected.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared, two physical cores per side.
- Alpine/musl only. Not repeated on glibc, unlike the default configuration in
  [D18](D18-glibc-control.md).
- Plaintext only.
- Five rounds.

## Related

- [D17](D17-mechanism-discriminator.md) -- the receive-buffer lever alone, and the mechanism
- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the cache-ceiling lever alone at 64 KB
- [D20](D20-pinning-and-cache-ceiling-256kb.md) -- the epoll cache-ceiling regression at 256 KB
- [D13](D13-profiling-at-256kb.md) -- where `stack64.log` and `stack256.log` were wrongly filed
- [D11](D11-buffer-rings-at-64kb.md) -- the remediation that did not work
