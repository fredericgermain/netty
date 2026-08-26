# C control experiment: can io_uring beat epoll on this host at all?

Confidence tags follow `benchmark-report/FINDINGS.md`.

Every netty io_uring measurement on this branch is netty's transport on one machine. That leaves an
unfalsified alternative: that `thor` or kernel 6.8 is simply a bad environment for io_uring, and that
what we attributed to netty's transport is really the host. This is the control that closes it. A
published C benchmark in which io_uring is faster than epoll is run here unchanged, and we ask
whether the published win reproduces.

**Headline: it does, partially, and the shape is the interesting part.** io_uring wins on `thor`, so
the host is not categorically hostile. But the win is 5-10% where the author published 40-70%, and
it decays with payload size on exactly the same curve netty's does: **1.09x at 1 KB, 0.99x at 8 KB,
0.82x at 64 KB.** The size dependence we found in netty is not netty's invention. It reproduces in
150 lines of hand-written C that never calls `POLL_ADD`.

---

## The benchmark

`frevib/io_uring-echo-server` and its companion `frevib/epoll-echo-server`, driven by
`haraldh/rust_echo_bench`. This is the pair that liburing issue
[#536](https://github.com/axboe/liburing/issues/536) treats as the reference point for
io_uring-vs-epoll network numbers, and it satisfies every requirement: plain C on liburing with no
framework, a matching epoll server by the same author written for direct comparison, and a published
table showing io_uring ahead.

| component | repository | commit |
|---|---|---|
| io_uring echo server | `github.com/frevib/io_uring-echo-server` | `dc00940baeec2ac577410dfa4d881d0852b01a08` (2024-01-20) |
| epoll echo server | `github.com/frevib/epoll-echo-server` | `22f325165c3e9749aca85a777cbb8f9b66ea7a27` (2020-02-29) |
| load generator | `github.com/haraldh/rust_echo_bench` | `920f8a5a2ab4d99ebb71bdc1b9fe9e62e303ecdf` (2019-01-17) |

Both servers are single-threaded and structurally symmetric: one event loop, one 2048-byte message
cap, echo back exactly what one read returned. The epoll server does `epoll_wait` (edge-triggered)
then one `recv` then one `send`. The io_uring server does `recv` with `IOSQE_BUFFER_SELECT`, then
`send`, then `provide_buffers` to return the buffer, all batched behind one
`io_uring_submit_and_wait`.

**Worth stating up front, because it bears directly on our netty mechanism claim: the io_uring server
does not submit `POLL_ADD`.** It relies on `IORING_FEAT_FAST_POLL` and refuses to start without it.
This is the arrangement netty's transport does *not* use, so this benchmark is close to a best case
for io_uring in exactly the dimension we believe netty gets wrong.

### The author's published numbers

Kernel 5.6.0-rc1 in a VMware Ubuntu 18.04 guest, 6 vcores on a 6-core 2.6 GHz MacBook Pro, 2 vcores
isolated with `isolcpus` and the server pinned there with `taskset`, client and server on the same
machine, 60-second runs. io_uring / epoll, computed from the published tables:

| bytes | c=1 | c=50 | c=150 | c=300 | c=500 | c=1000 |
|---|---|---|---|---|---|---|
| 128 | 0.99x | 1.05x | 1.25x | 1.49x | 1.68x | 1.60x |
| 512 | 1.00x | 1.11x | 1.31x | 1.43x | 1.56x | 1.46x |
| 1000 | 1.06x | 1.06x | 1.25x | 1.52x | 1.49x | 1.40x |

The published story is that io_uring's lead grows with connection count and peaks around 500-1000
connections at roughly 1.5-1.7x.

---

## How it was run here

`thor`: Intel i5-10300H, 4 physical cores / 8 logical, 62 GB, Ubuntu, kernel 6.8.0-57-generic,
`kernel.io_uring_disabled = 0`. Host was 96-98% idle by `vmstat` before and after every round
(`uptime` reads a stale load average of ~7 on this box and should be ignored).

Built inside `ubuntu:24.04` with `liburing-dev 2.5-1build1` and gcc 13.3.0, because we have no root
on the host. Containers run `--network=host --security-opt seccomp=unconfined`; without the seccomp
override docker's default profile blocks `io_uring_setup` and the server would exit at startup rather
than be measured. Ring initialisation and buffer-selection support were verified functionally before
any measurement.

- **Physical-core pinning.** Server container `--cpuset-cpus=0,1,4,5`, client container
  `--cpuset-cpus=2,3,6,7`. `0,4` / `1,5` / `2,6` / `3,7` are the SMT sibling pairs on this box, so
  this gives each side two whole physical cores. `0-3` vs `4-7` would have put both sides on the same
  physical cores.
- **5 interleaved rounds per cell**, 12 seconds each, transports alternating within every round and
  the leading transport swapping each round.
- **Spread is full observed min-max across the 5 rounds**, printed beside the median. Where the two
  transports' ranges overlap the cell is called not established.
- Free port picked per run by scanning 19990-20050; 19999 was held by an unrelated orphan for the
  whole session, as it has been before. Clients wrapped in `timeout`.
- 180 runs total. **Zero failed runs, zero dropped connections, zero `Read error!` lines.**

### The one modification, and why

Upstream caps a single echo at `MAX_MESSAGE_LEN 2048`, which is why the published table stops at 1000
bytes. Above that the epoll server is not merely slow, it is unsound: it is edge-triggered and does
exactly one `recv` per event, so a reply larger than the buffer is never fully drained. To reach the
8 KB and 64 KB cells that let us compare shapes against netty, a second set of binaries raises
`MAX_MESSAGE_LEN` to 65536 **identically in both servers**, and the client reads a reply to completion
instead of treating the first short read as fatal. `BUFFERS_COUNT` drops to 1024 in the io_uring
server to keep its static buffer pool at 64 MB rather than 256 MB; ping-pong holds at most one buffer
per connection, so that covers every connection count swept.

The small-payload cells were run on the unmodified binaries, and the 1 KB cell was measured on both
sets as a cross-check: 1.08x on the stock binaries at 1000 bytes, 1.09x on the patched binaries at
1024 bytes. The patch does not move the result.

---

## Result 1: the reproduction run, unmodified binaries

**[SOLID]** 5 interleaved rounds, 12 s each, full min-max spreads, raw output in
`logs/results-stock.tsv` and `logs/run-stock.log`.

| bytes | conns | epoll req/s, median [min-max] | io_uring req/s, median [min-max] | io_uring / epoll | separated |
|---|---|---|---|---|---|
| 128 | 1 | 69,888 [69,472-70,661] | 68,406 [67,819-68,965] | 0.98x | yes |
| 128 | 50 | 195,584 [194,155-198,760] | 214,083 [212,766-215,910] | **1.09x** | yes |
| 128 | 300 | 186,764 [186,367-188,827] | 197,837 [196,691-198,923] | **1.06x** | yes |
| 128 | 1000 | 156,528 [156,323-157,225] | 155,291 [154,082-155,643] | 0.99x | yes |
| 512 | 1 | 68,745 [68,092-69,648] | 67,578 [67,381-68,003] | 0.98x | yes |
| 512 | 50 | 193,659 [191,856-194,744] | 213,270 [212,382-213,773] | **1.10x** | yes |
| 512 | 300 | 182,681 [181,989-185,295] | 193,478 [192,779-195,786] | **1.06x** | yes |
| 512 | 1000 | 151,586 [150,813-152,251] | 148,249 [146,993-150,429] | 0.98x | yes |
| 1000 | 1 | 67,137 [66,562-67,266] | 65,898 [65,510-66,276] | 0.98x | yes |
| 1000 | 50 | 191,838 [190,710-192,720] | 207,366 [206,183-208,815] | **1.08x** | yes |
| 1000 | 300 | 175,792 [171,368-175,919] | 183,867 [181,712-185,753] | **1.05x** | yes |
| 1000 | 1000 | 148,729 [148,398-149,264] | 141,133 [140,238-143,573] | 0.95x | yes |

Spreads are remarkably tight, typically under 1.5% of the median, and every cell separates. This is
about as clean as a loopback measurement on a shared box gets.

**io_uring beats epoll on `thor`.** The win is real and repeatable at 50 and 300 connections,
1.05x-1.10x, and it holds across all three published payload sizes. The alternative hypothesis this
experiment existed to kill -- that io_uring simply cannot win on this host or this kernel -- is dead.

## Result 2: payload sweep, symmetrically patched binaries

**[SOLID]** Same protocol, raw output in `logs/results-big.tsv` and `logs/run-big.log`.

| bytes | conns | epoll req/s, median [min-max] | io_uring req/s, median [min-max] | io_uring / epoll | separated |
|---|---|---|---|---|---|
| 1024 | 50 | 191,912 [191,231-193,544] | 209,537 [208,606-210,404] | **1.09x** | yes |
| 1024 | 300 | 176,620 [176,414-179,212] | 183,874 [181,502-185,547] | **1.04x** | yes |
| 8192 | 50 | 156,207 [155,100-157,699] | 154,875 [153,483-156,524] | 0.99x | **no, ranges overlap** |
| 8192 | 300 | 118,399 [117,635-120,314] | 112,694 [111,825-114,426] | 0.95x | yes |
| 65536 | 50 | 44,446 [44,199-45,416] | 36,621 [36,464-36,722] | **0.82x** | yes |
| 65536 | 300 | 38,090 [38,011-38,213] | 31,861 [31,785-31,925] | **0.84x** | yes |

At 8 KB / 50 connections the two ranges overlap, so that cell is a tie and not a small io_uring
deficit. Everything else separates cleanly.

The curve is monotone and steep. io_uring goes from a 9% win to an 18% loss purely by growing the
payload, with connection count held fixed.

---

## Answering the four questions

### 1. Does io_uring beat epoll on `thor`?

**Yes, at small payloads and moderate connection counts.** 1.09x-1.10x at 50 connections and
1.04x-1.06x at 300 connections, for payloads of 1 KB and below, with min-max spreads that do not
overlap. It loses slightly at 1 connection (0.98x, where there is nothing to batch) and at 1000
connections (0.95x-0.99x), and loses substantially at 64 KB (0.82x-0.84x).

### 2. How does that compare to the published numbers?

**Same direction at 50 connections, much smaller, and the connection-count trend is inverted.**

| conns | published (512 B) | measured here (512 B) |
|---|---|---|
| 1 | 1.00x | 0.98x |
| 50 | 1.11x | 1.10x |
| 300 | 1.43x | 1.06x |
| 1000 | 1.46x | 0.98x |

The 50-connection cell reproduces almost exactly. Past that the published curve keeps climbing and
ours falls away. Two observations constrain the explanation, carefully:

- **The absolute numbers here are about five times the published ones at low connection counts**:
  69,888 req/s at 1 connection against a published 13,177. The published environment was a VMware
  guest on kernel 5.6.0-rc1 with two isolated vcores. Syscalls in a 2020-era VM with a full set of
  early speculative-execution mitigations are expensive, and io_uring's central advantage is
  amortising syscalls. On bare metal with a 2025 kernel there is much less syscall cost to amortise,
  which is the most economical account of why a 40-70% win shrinks to 5-10%.
- **epoll's high-connection scaling is what changed most.** Published epoll fell from 135,973 at 50
  connections to 107,257 at 1000, a 21% collapse; ours falls from 193,659 to 151,586, also about 22%.
  The difference is that published io_uring *rose* from 150,444 to a peak of 194,701 at 500, whereas
  ours declines monotonically from 213,270. io_uring's scaling with connection count is what failed to
  reproduce, not epoll's. **[UNCERTAIN]** why: 4 physical cores here against 6 vcores there, a
  different kernel generation, and a single-threaded server that saturates one core in both cases are
  all plausible and this experiment does not separate them.

### 3. Is the shape similar to netty's, or opposite? -- the key question

**Similar. Strikingly so.** This is the most important result here.

| payload | netty io_uring / epoll | C io_uring / epoll |
|---|---|---|
| 1 KB | 0.63-0.85x | **1.09x** (c=50), 1.04x (c=300) |
| 8 KB | (not measured) | 0.99x (c=50), 0.95x (c=300) |
| 64 KB | 0.43-0.55x | **0.82x** (c=50), 0.84x (c=300) |

Both curves fall with payload size, and they fall by a comparable amount. C io_uring drops about 25
percentage points of relative throughput going from 1 KB to 64 KB (1.09 -> 0.82). Netty drops
roughly 20-30 points over the same span. The curves are close to parallel; netty's simply sits 25-40
points lower.

This is not "io_uring wins everywhere in C", and it is not the opposite of netty's shape. It is
netty's shape with an offset, which is a more informative outcome than either.

Note also that the connection-count axis inverts relative to the published results while the
payload-size axis matches netty's. Whatever is happening on this host penalises io_uring as work per
event grows, in C and in Java alike.

### 4. What does this license us to conclude about netty?

Stating the boundaries explicitly, because this is where the experiment is easiest to over-read.

**What it establishes:**

- **The host and kernel are not the whole story.** io_uring measurably beats epoll on this exact
  machine, kernel, and container setup. Any claim of the form "io_uring can't win on `thor`" is now
  falsified, and netty's io_uring deficit at 1 KB cannot be waved away as an environment artifact.
  It is a real gap against a baseline that a C server clears.
- **The size dependence is environmental, not netty's invention.** This matters and it partly revises
  what we have been saying. We attributed netty's widening deficit at large payloads to netty's
  `POLL_ADD` + `RECV` pattern -- two operations and two completions per read, so more reads per
  message multiplies io_uring's per-read overhead. That mechanism is still coherent, but **the same
  decay appears in a C server that never issues `POLL_ADD`**, going from 1.09x to 0.82x on the same
  sweep. So `POLL_ADD` cannot be the cause of the size dependence. The more defensible general form
  is that *any* per-read op overhead multiplies with read count, and io_uring's per-read overhead on
  this kernel and this loopback path is higher than a plain `recv` syscall's. netty's `POLL_ADD`
  pattern would add to that, not create it.
- **A rough decomposition, with the caveat below.** At 64 KB the environment costs io_uring about 18%
  against epoll before netty is involved at all. netty's io_uring sits at 43-55%. Very loosely, the
  environment accounts for something under half the gap and netty's transport for the rest.

**What it does not establish:**

- **A C echo server is not doing netty's work.** It is single-threaded where netty is multi-threaded;
  it does no allocation, no GC, no `ByteBuf` pooling, no pipeline dispatch, no JNI boundary crossing.
  It also uses kernel-provided buffer selection, which netty's transport does not. The 0.82x figure
  bounds the environment; it does not measure what netty would score if its transport were written the
  way frevib's is.
- **The decomposition above is not additive arithmetic.** Treating 0.82 and 0.50 as separable factors
  assumes the two effects compose independently, which nothing here shows. Read it as an
  order-of-magnitude sense of how the gap splits, not as a measurement. **[UNCERTAIN]**
- **This says nothing about the `POLL_ADD` hypothesis's magnitude in netty.** It rules `POLL_ADD` out
  as the explanation for the *shape*, but the offset between the two curves remains unexplained by
  this experiment, and `POLL_ADD` remains a live candidate for it. Testing that needs a netty-side
  change or a C server modified to use `POLL_ADD` + `RECV`, which is the obvious next control and was
  not run here.

---

## Scope limits that apply to everything above

- **Loopback.** The syscall epoll pays for is close to a memcpy, so io_uring's syscall-amortisation
  advantage has very little to amortise. This is the least favourable possible setting for io_uring
  and the same limit applies to every netty number on this branch.
- **Kernel 6.8 predates the features that matter most for the large-payload case.** send-zc buffer
  coalescing and send/recv bundles landed in 6.10; `IORING_ENTER_NO_IOWAIT` in 6.15. The 64 KB cell in
  particular is measuring an io_uring that is missing the machinery built for it. A 6.10+ kernel could
  move the 0.82x figure substantially and this result should not be quoted as a property of io_uring
  in general.
- **Client and server share one 4-core machine**, as they did in the published run. Both sides are
  competing for the same memory bandwidth and the same loopback path.
- **Both servers are single-threaded.** The connection-count axis therefore measures how one event
  loop copes with fan-out, not how the transports scale across cores.

## Files

- `Dockerfile` -- build image, commits pinned, both stock and patched binaries
- `patch-bench.pl` -- the read-to-completion change to `rust_echo_bench`
- `run-matrix.sh` -- the runner: pinning, interleaving, port scan, per-run logging
- `analyse.py` -- median and min-max tables from the raw TSVs
- `logs/results-stock.tsv`, `logs/results-big.tsv` -- one row per run, 180 rows
- `logs/run-stock.log`, `logs/run-big.log`, `logs/full-run.log` -- raw client output for every run

Reproduce with:

```
scp Dockerfile patch-bench.pl run-matrix.sh thor.mf:~/c-control/
ssh thor.mf 'cd ~/c-control && docker build --network=host -t iouring-control:latest .'
ssh thor.mf '~/c-control/run-matrix.sh stock 5 12 && ~/c-control/run-matrix.sh big 5 12'
python3 analyse.py logs/results-stock.tsv logs/results-big.tsv
```
