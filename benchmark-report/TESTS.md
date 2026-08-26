# Test catalogue

Every measurement run in this work, one file per test under `tests/`. Companion to `FINDINGS.md`,
which draws conclusions; this tree is the evidence.

Each test file records the question it was run to answer, the full configuration, the result verbatim,
what it does and does not establish, the exact path to its raw data, every caveat, and links to the
tests that supersede or contradict it.

Confidence tags are the same as in `FINDINGS.md`:

- **[SOLID]** multiple interleaved rounds, spreads recorded, raw output still retrievable
- **[SOLID, RECALLED]** measured carefully, but the numbers reached this document through a
  conversation summary rather than raw output I can still read. Believed correct, re-run before
  publishing an exact digit
- **[SINGLE RUN]** one measurement, no spread
- **[UNCERTAIN]** something specific is missing, stated each time
- **[WITHDRAWN]** claimed then disproved

---

## Part A: TLS handshake matrix (JMH, netty microbench)

| id | title | question | confidence | file |
|---|---|---|---|---|
| A1 | Microbench jar on Alpine | Does netty's shaded microbench jar run the SSL benchmarks at all? | SOLID, RECALLED | [A1](tests/A1-microbench-jar-on-alpine.md) |
| A2 | tcnative 2.0.81 on Alpine, both arches | Does released boringssl-static load on musl, and does the failure differ by architecture? | SOLID, RECALLED | [A2](tests/A2-tcnative-2081-alpine-both-arches.md) |
| A3 | openssl-dynamic as an Alpine workaround | Does the other flavour of the same released tcnative load where boringssl-static does not? | SOLID | [A3](tests/A3-openssl-dynamic-alpine-workaround.md) |
| A4 | libc effect by tcnative flavour | Is the musl handshake penalty a property of musl or of one flavour? | SOLID | [A4](tests/A4-libc-effect-by-tcnative-flavour.md) |
| A5 | Key exchange group sweep | Is BoringSSL's default TLS 1.3 group the post-quantum hybrid, and what does it cost? | SOLID | [A5](tests/A5-key-exchange-group-sweep.md) |
| A6 | TLS 1.2 vs TLS 1.3, group controlled | How much of the TLS 1.3 gap is the protocol and how much is the group? | SOLID | [A6](tests/A6-tls12-vs-tls13-group-controlled.md) |
| A7 | What a real cloud endpoint negotiates | Is the post-quantum hybrid something a mainstream endpoint actually selects today? | SOLID, RECALLED | [A7](tests/A7-cloud-endpoint-negotiation.md) |
| A8 | Negative controls | Would anything catch a cell reporting the wrong library's number, or a number at all? | SOLID | [A8](tests/A8-negative-controls.md) |
| A9 | Never executed | What in Part A was built but never measured? | UNCERTAIN | [A9](tests/A9-never-executed.md) |
| A10 | Patched tcnative clears the matrix | Does boringssl-static built from patched 2.0.82-SNAPSHOT run on both Alpine images? | SOLID | [A10](tests/A10-patched-tcnative-matrix-gate.md) |

## Part B: QUIC musl fix

| id | title | question | confidence | file |
|---|---|---|---|---|
| B | QUIC musl fix | Can the tcnative #997 approach be ported to `codec-native-quic`? | SOLID | [B](tests/B-quic-musl-fix.md) |

## Part C: Load test harness

| id | title | question | confidence | file |
|---|---|---|---|---|
| C | Load test harness design | Not a test. What every Part D number is a number of. | SOLID | [C](tests/C-harness-design.md) |

## Part D: Load test experiments, chronological

| id | title | question | confidence | file |
|---|---|---|---|---|
| D1 | First 10k-connection runs | At 10,000 connections, which transport is faster, plaintext and with TLS? | SINGLE RUN | [D1](tests/D1-first-10k-connection-runs.md) |
| D2 | Ring size sweep | Is io_uring's deficit caused by a completion queue that is too small? | SOLID (contains a WITHDRAWN 292x claim) | [D2](tests/D2-ring-size-sweep.md) |
| D3 | Interleaved transport comparison | With cells interleaved so each sees the same drift, how do the transports compare? | SOLID | [D3](tests/D3-interleaved-transport-comparison.md) |
| D4 | Q3 instrumented run | Where does io_uring's extra CPU go, and on which side? | SOLID (two claims later WITHDRAWN) | [D4](tests/D4-q3-cpu-accounting.md) |
| D5 | GC hypothesis | Is the swing explained by garbage collection pauses? | SOLID | [D5](tests/D5-gc-hypothesis.md) |
| D6 | async-profiler ctimer, plaintext client | Which frames burn io_uring's extra CPU inside the client? | SOLID | [D6](tests/D6-async-profiler-ctimer-plaintext-client.md) |
| D7 | Buffer rings and multishot recv at 1 KB | Does a provided buffer ring close the plaintext gap? | SOLID | [D7](tests/D7-buffer-rings-at-1kb.md) |
| D8 | io_wq thread census | Is the missing profiler time being burned in `iou-wrk-*` kernel workers? | SOLID | [D8](tests/D8-io-wq-thread-census.md) |
| D9 | Cross-transport 2x2 | If only one side uses io_uring, how much of the deficit appears? | SOLID (withdraws two D4 claims) | [D9](tests/D9-cross-transport-2x2.md) |
| D10 | Payload sweep and zero-copy send | At what message size does io_uring stop losing, and can SEND_ZC make it win? | SINGLE RUN per cell | [D10](tests/D10-payload-sweep-and-zero-copy.md) |
| D11 | Buffer rings at 64 KB | Does the buffer ring help at the size where the deficit is three times larger? | SOLID | [D11](tests/D11-buffer-rings-at-64kb.md) |
| D12 | Kernel profiling at 1 KB | With kernel frames resolving, where does the time go, and is IOSQE_FIXED_FILE worth it? | SOLID | [D12](tests/D12-kernel-profiling-at-1kb.md) |
| D13 | Profiling at 256 KB, both sides | At io_uring's worst size, does the cost have a signature? | SINGLE RUN | [D13](tests/D13-profiling-at-256kb.md) |
| D14 | Pooled memory measurement | Does the io_uring server really hold more pooled direct memory, and does a ring fix it? | SINGLE RUN per cell | [D14](tests/D14-pooled-memory-measurement.md) |
| D15 | Equal-rate open loop | At equal load rather than saturation, is io_uring intrinsically more expensive? | SINGLE RUN per cell | [D15](tests/D15-equal-rate-open-loop.md) |
| D16 | Pinning and cache ceiling, 64 KB | How large is the SMT pinning artifact, and does raising the cache ceiling fix the deficit? | SOLID | [D16](tests/D16-pinning-and-cache-ceiling-64kb.md) |
| D17 | Mechanism discriminator | Three hypotheses, three levers -- which lever moves? | SOLID | [D17](tests/D17-mechanism-discriminator.md) |
| D18 | glibc control | Does the size cliff reproduce off musl? | SOLID | [D18](tests/D18-glibc-control.md) |
| D19 | TLS warm-up and TLS ordering | Is io_uring's TLS climb a real warm-up effect or machine state? | SOLID for the trend, UNCERTAIN for the ordering | [D19](tests/D19-tls-warmup-and-ordering.md) |
| D20 | Pinning and cache ceiling, 256 KB | Same sweep at the size where io_uring is at its worst. | SOLID | [D20](tests/D20-pinning-and-cache-ceiling-256kb.md) |
| D21 | Stacked remediation | Are the receive-buffer and cache-ceiling levers additive, and does epoll benefit equally? | SOLID | [D21](tests/D21-stacked-remediation.md) |

**A10, D20 and D21 are new.** They were recovered by reading `x86run.log`, `pc256.log`, `stack64.log`
and `stack256.log`, all of which this catalogue previously listed as never read. D20 and D21 in
particular are not reflected in `FINDINGS.md` and should be folded in: D21 is the largest single
improvement to io_uring measured anywhere in this branch.

---

## Where the raw data lives

**Committed in this branch**, under `benchmark-report/`:

| path | what |
|---|---|
| `logs/pc64.log` | pinning x cache-ceiling sweep, 64 KB -- [D16](tests/D16-pinning-and-cache-ceiling-64kb.md) |
| `logs/pc256.log` | same at 256 KB -- [D20](tests/D20-pinning-and-cache-ceiling-256kb.md) |
| `logs/mech64.log` | SO_SNDBUF vs receive-buffer discriminator -- [D17](tests/D17-mechanism-discriminator.md) |
| `logs/stack64.log`, `logs/stack256.log` | stacked-remediation sweeps -- [D21](tests/D21-stacked-remediation.md). **Not profile stack extracts**, despite the earlier description here. |
| `logs/tlswarm.log` | ten consecutive TLS rounds per transport -- [D19](tests/D19-tls-warmup-and-ordering.md) |
| `logs/glibc.log` | glibc control at 64 KB -- [D18](tests/D18-glibc-control.md) |
| `logs/inversion2.log` | five-round interleaved transport comparison -- [D3](tests/D3-interleaved-transport-comparison.md) |
| `logs/inversion.log` | **the failed first attempt.** Contains no data, only `line 25: t: unbound variable` five times. |
| `logs/q3.log` | instrumented CPU/GC run -- [D4](tests/D4-q3-cpu-accounting.md), [D5](tests/D5-gc-hypothesis.md) |
| `logs/load4.log` | ring sweep, saturation and open-loop sections -- [D1](tests/D1-first-10k-connection-runs.md), [D2](tests/D2-ring-size-sweep.md) |
| `logs/load3.log` | the same script before port scanning: every cell `SERVER FAILED` |
| `logs/load.log`, `logs/load2.log` | two earlier partial attempts, both truncated |
| `logs/reactor.log` | **a maven build log**, not a load test run. `microbench` jar, `BUILD SUCCESS`, 2026-08-25T12:41:21Z. |
| `logs/x86run.log` | the full TLS matrix, released and patched -- [A2](tests/A2-tcnative-2081-alpine-both-arches.md), [A3](tests/A3-openssl-dynamic-alpine-workaround.md), [A8](tests/A8-negative-controls.md), [A10](tests/A10-patched-tcnative-matrix-gate.md) |
| `logs/insight.log` | insight-mode console transcript -- [A4](tests/A4-libc-effect-by-tcnative-flavour.md) |
| `logs/groups.log` | key exchange group sweep -- [A5](tests/A5-key-exchange-group-sweep.md), [A6](tests/A6-tls12-vs-tls13-group-controlled.md) |
| `logs/jar-*.log` | four maven build logs for the four benchmark jar flavours, all `BUILD SUCCESS` |
| `jmh/insight/*.jsonl`, `jmh/insight-bssl/*.jsonl` | six files of tagged JMH records -- the primary source for [A4](tests/A4-libc-effect-by-tcnative-flavour.md) |
| `scripts/thor-*.sh`, `scripts/stacks.sh` | eighteen sweep and profiling scripts, **all using the old SMT-sibling pinning** |

**Also committed**: `loadtest/` (the harness), `loadtest/README.md` (the running narrative),
`loadtest/scripts/*.sh` (the five corrected-pinning sweeps: `thor-pincache.sh`, `thor-mech.sh`,
`thor-stack.sh`, `thor-tlswarm.sh`, `thor-glibc.sh`), `.github/scripts/tls-matrix/` (the JMH matrix
harness), `.github/workflows/ci-tls-matrix.yml`.

**On `thor`** (reachable as `thor.mf`), under `/home/fred/tls-matrix/`, and **not committed**:

| path | what | needed by |
|---|---|---|
| `prof/*.collapsed` | async-profiler ctimer output, 1 KB | [D6](tests/D6-async-profiler-ctimer-plaintext-client.md) |
| `kprof/*.collapsed` | async-profiler cpu output with kernel frames, 1 KB | [D12](tests/D12-kernel-profiling-at-1kb.md) |
| `bigprof/*.collapsed` | same at 256 KB, both sides | [D13](tests/D13-profiling-at-256kb.md) |

**Never committed and no longer recoverable in this branch**: run logs for
[D6](tests/D6-async-profiler-ctimer-plaintext-client.md),
[D7](tests/D7-buffer-rings-at-1kb.md), [D8](tests/D8-io-wq-thread-census.md),
[D9](tests/D9-cross-transport-2x2.md), [D10](tests/D10-payload-sweep-and-zero-copy.md),
[D11](tests/D11-buffer-rings-at-64kb.md), [D12](tests/D12-kernel-profiling-at-1kb.md),
[D13](tests/D13-profiling-at-256kb.md), [D14](tests/D14-pooled-memory-measurement.md) and
[D15](tests/D15-equal-rate-open-loop.md). Their driver scripts are committed; their output is not.
Each of those files says so at the top of its Raw data section. **This is now the largest gap in the
evidence**, and it covers most of Part D's profiling and single-run work.

**The pinning distinction matters and is recorded per test.** Scripts under
`benchmark-report/scripts/` pin server to `0-3` and client to `4-7`, which on thor are SMT siblings
sharing four physical cores. Scripts under `loadtest/scripts/` pin `0,1,4,5` and `2,3,6,7`, which are
whole physical cores. D1-D15 and D19 use the former; D16, D17, D18, D20 and D21 use the latter.
[C](tests/C-harness-design.md) has the full table.

## Open items never completed

- **[UNCERTAIN] Open-loop p99 anomaly at small payloads**: p50 around 100 us against p99 around 1 s
  with the target rate met. Never explained. **Now verifiable**: `benchmark-report/logs/load4.log`
  section C shows `epoll plaintext @100k` at `p50us=111 p99us=1095679` with
  `mode=open-loop:target-met`. The same section shows io_uring behaving qualitatively differently at
  the same target, `p50us=337663 p99us=3547135`, which was never recorded and is worth its own look.
- **[UNCERTAIN] The async-profiler shortfall on io_uring**: cause unknown, io_wq falsified
  ([D8](tests/D8-io-wq-thread-census.md)). Measured at 2.4x under `ctimer` and 3.5x under `cpu`.
- **A `--prealloc` control for [D17](tests/D17-mechanism-discriminator.md).** In progress in the
  working tree as `loadtest/scripts/thor-prealloc.sh` and `thor-allocprof.sh`, uncommitted and unrun.
  It asks whether the reads-per-message conclusion is a property of netty or of a load generator that
  memset its payload on every request. **This is the most consequential open item in Part D.**
- **Run logs for ten Part D tests were never committed.** See the table above.
- 8 KB payload row: never re-run with rounds or corrected pinning.
  ([D20](tests/D20-pinning-and-cache-ceiling-256kb.md) now covers 256 KB and shows the pinning
  correction is a no-op at that size.)
- **No `isUsable()` assertion on the provided buffer ring.** Both
  [D7](tests/D7-buffer-rings-at-1kb.md) and [D11](tests/D11-buffer-rings-at-64kb.md) are
  uninterpretable without it: a ring that never engaged and a ring that engaged without helping give
  the same numbers.
- **The aarch64 arm of [A2](tests/A2-tcnative-2081-alpine-both-arches.md) has no committed log**, and
  it carries the more severe half of that finding.
- **[A7](tests/A7-cloud-endpoint-negotiation.md) has no artifact at all.** One `openssl s_client`
  run, undated, client configuration unrecorded.
- **Part B has no execution evidence**, only source evidence. `QuicMuslCheck.java` and `verify.sh`
  exist on `quic-musl-compat`; no transcript of either running does.
- `ci-tls-matrix.yml`: committed, never executed. Microbench payload-size and certificate-type axes:
  never started.
- The Medium draft written earlier in this work
  (`~/.claudem/jobs/6c46f506/tmp/medium-draft.md`, roughly 1400 words): **[UNCERTAIN]** that path is a
  job scratch directory and may no longer exist. It should be treated as lost and rewritten from
  `FINDINGS.md`.
- Nothing is pushed anywhere. The netty checkout has only `origin` pointing at upstream netty/netty,
  so there is no fork remote to push to.

## If you want these numbers to survive ten years

The fragile parts, in order of fragility:

1. **The ten Part D tests whose run logs were never committed.** This has replaced the scratch-script
   problem as the worst gap. The scripts survived; the output did not. Every profiling result in Part
   D -- D6, D12, D13 -- rests on collapsed stack files that exist only on thor, and D15, which carries
   a large share of the argument, rests on a single unrecorded run pair.
2. **[A7](tests/A7-cloud-endpoint-negotiation.md).** One undated probe, no transcript, and it is
   exactly the kind of fact that changes. Re-run and capture it before publishing.
3. **The remaining `[SOLID, RECALLED]` tags**: A1, A2 and A7. A2's aarch64 half and A1's four-bug
   enumeration are the two worth recovering; both are cheap.
4. **thor itself.** Everything here is one machine, reachable over a VPN that dropped mid-session at
   least once. Kernel version (6.8.0-57-generic), core count (4 physical, 8 logical) and SMT topology
   are all load-bearing for the io_uring results, and the SMT topology has already produced one
   documented methodology error.
5. **The snapshot coordinates.** `netty-tcnative` 2.0.82.Final-SNAPSHOT and netty 4.2.18-SNAPSHOT can
   both change under the same coordinate. Every Part A number and every Part D number is against a
   snapshot.
