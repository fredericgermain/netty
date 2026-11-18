# benchmark-report

Measurement work on this fork: netty on Alpine/musl, TLS, io_uring against epoll, QUIC. Not upstream
netty material. Read `FINDINGS.md` for conclusions, `TESTS.md` for the evidence index,
`ENVIRONMENT.md` for how to run a benchmark that means something.

## Where things are

| path | what | when to reach for it |
|---|---|---|
| `FINDINGS.md` | the conclusions, with confidence tags | before quoting any number |
| `ENVIRONMENT.md` | how to run a benchmark that is not corrupted | before designing a run |
| `TESTS.md` | one row per test, pointing at `tests/` and the raw data | to find what backs a claim |
| `REPLICATION.md` | the two-machine protocol and its pass/fail criteria | before any run on the second machine |
| `quic/lib.sh` | the shared harness: port scan, quiet gates, container lifecycle, per-cell frequency, throttle and wi-fi deltas | sourced by every sweep; extend here rather than reimplementing |
| `scripts/topology.sh` | derives cpusets from `thread_siblings_list` | never hardcode a cpuset; source this |
| `scripts/calibrate.sh` | the fixed compute and network anchors | before and after every machine's set |
| `scripts/bench-usb.sh` | readiness gate for a live session, per-machine clock caps | `check` before measuring, on any host |
| `scripts/usb-build.sh` | writes the replication USB key | destructive; needs `--yes` and a removable device |
| `scripts/usb-setup.sh` | brings a booted live session up, wi-fi first | once per boot |
| `scripts/endpoint-probe.sh` | what a real TLS endpoint negotiates, offer by offer, with a repeat tally | re-run before publishing any A7 figure; the answer moves with fleet rollouts |
| `c-control/IMAGE-PROVENANCE.md` | what is inside `iouring-control:latest`, the C client cell C runs | before trusting or rebuilding cell C |
| `jmh/`, `logs/`, `c-control/`, `quic/`, `tests/` | raw output and per-area harnesses | |

Host characterisation (fan curves, core sweeps, `bench-tuning.sh`) lives outside this repo in
`~/workspaces/fred/dell-xps-9500-bench-rig`, because it describes a laptop rather than netty.

## Rules this work learned the hard way

- **Never infer topology from cpuset numbering.** `0-3` and `4-7` are SMT sibling pairs on a 4-core
  part, not two disjoint halves. Source `scripts/topology.sh`.
- **Abort, never fall back.** Netty silently drops to NIO when a native transport is unavailable, so
  every cell asserts what it claims to measure and fails loudly instead.
- **Interleave at least five rounds** and report the spread. If a range overlaps the cell it is
  compared against, the result is "not established", not "a small effect".
- **A foreign container, a nonzero throttle delta, or an outlying `wifiDelta` disqualifies a cell.**
  Contention has been observed to invert a transport ordering, not merely add noise.
- **Archive raw output, not summaries.** Every `[SOLID, RECALLED]` tag exists because a number
  reached a document without its raw record.
- The sweeps run workloads in **containers**; the host libc is not the measurement's libc.
