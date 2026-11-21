# benchmark-report

Measurement work on this fork: netty on Alpine/musl, TLS, io_uring against epoll, QUIC. Not upstream
netty material. Read `RUNBOOK.md` for how a sweep runs end to end, `FINDINGS.md` for conclusions,
`TESTS.md` for the evidence index, `ENVIRONMENT.md` for why each methodology rule exists.

## Where things are

| path | what | when to reach for it |
|---|---|---|
| `FINDINGS.md` | the conclusions, with confidence tags | before quoting any number |
| `RUNBOOK.md` | what happens when a sweep runs, in order: the four stages, the tuning and the measurements that chose it, the two latency modes, and what throws a cell away | read this before designing a run; `ENVIRONMENT.md` for why each rule exists |
| `ENVIRONMENT.md` | why each methodology rule exists, with the failure that produced it | when a rule in the runbook needs justifying, or to design something new |
| `TESTS.md` | one row per test, pointing at `tests/` and the raw data | to find what backs a claim |
| `REPLICATION.md` | the two-machine protocol and its pass/fail criteria | before any run on the second machine |
| `quic/lib.sh` | the shared harness: port scan, quiet gates, container lifecycle, per-cell frequency, throttle, wi-fi and usb-write deltas | sourced by every sweep; extend here rather than reimplementing |
| `scripts/topology.sh` | derives cpusets from `thread_siblings_list` | never hardcode a cpuset; source this |
| `scripts/calibrate.sh` | the fixed compute and network anchors | before and after every machine's set |
| `scripts/bench-usb.sh` | readiness gate for a live session, per-machine clock caps | `check` before measuring, on any host |
| `scripts/hwinfo.sh` | the parts and the BIOS state a run was taken on, with a `BIOSHASH` and a one-line `HWSUM` label | once per machine before any cell; carried over from the 9380 standby kit |
| `scripts/usb-build.sh` | writes the replication USB key | destructive; needs `--yes` and a removable device |
| `scripts/go` | the whole live-session bring-up in one word | cloud-init runs it automatically every boot; by hand it is `sudo mount LABEL=CIDATA /mnt && sudo /mnt/go`. It sits at the key's root, not in `scripts/`, because the point is to be short to type |
| `scripts/cloud-init/` | the NoCloud seed (`user-data`, `meta-data`, `network-config`) that makes the key boot into `go` with nothing typed | before changing how the key boots; `REPLICATION.md` records why each file has the shape it does |
| `scripts/boot/grub.cfg` | the patched boot menu, entry 0 carrying `toram systemd.unit=multi-user.target` | to change the kernel args; it must stay <= the original 543 bytes or `patch_grub` refuses it |
| `scripts/usb-setup.sh` | brings a booted live session up, wi-fi first | once per boot |
| `scripts/endpoint-probe.sh` | what a real TLS endpoint negotiates, offer by offer, with a repeat tally | re-run before publishing any A7 figure; the answer moves with fleet rollouts |
| `scripts/group-identity.sh` | reads `SSL_get_negotiated_group` off a netty/BoringSSL server under four client offers | to check what a provider actually selects, rather than inferring it from a score |
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
- **A foreign container, a nonzero throttle delta, or an outlying `wifiDelta` or `usbDelta`
  disqualifies a cell.** Contention has been observed to invert a transport ordering, not merely
  add noise. On the replication key docker's graph is on flash, so `usbDelta` is the same argument
  applied to the key: measure it per cell rather than assume the stick is out of the way.
- **Archive raw output, not summaries.** Every `[SOLID, RECALLED]` tag exists because a number
  reached a document without its raw record.
- The sweeps run workloads in **containers**; the host libc is not the measurement's libc.
