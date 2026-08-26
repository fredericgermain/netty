# Q1. QUIC against TCP+TLS, handshake rate and steady throughput

**Confidence:** WITHDRAWN, awaiting a clean re-run. Do not quote any number from the first attempt.
**Date:** first attempt 2026-08-26 20:52-20:59:56 BST
**Question:** at equal payload and equal connection count, how does QUIC compare with TCP+TLS on
handshake rate and on steady throughput, and does QUIC show the size-dependent decay that netty's
io_uring and the C io_uring echo server both show?

## Why the first attempt was withdrawn

Two independent problems, either of which is disqualifying on its own.

**1. It was contended for its last three minutes.** The sweep passed its starting gate -- the host
was verified clean, no foreign containers, 100% CPU idle -- and then a neighbouring agent's
three-phase experiment started **at 20:57:00**, while this sweep was still running. It finished at
**20:59:56**. So roughly the last three minutes of a nine-minute sweep, which is the back part of
rounds 4 and 5, ran against a second full-machine workload.

That is not a caveat on this host. A contended round has been observed here to **invert a transport
ordering**, not merely widen its spread: a cell that reads 192k against 210k on a quiet host was
measured at 74k against 153k while contended. A contended cell cannot be told from a clean one by
looking at its number, so the correct action is to discard rather than to annotate. Since the
contention spans an unknown boundary inside the round structure, the whole sweep goes.

**2. The CPU governor changed underneath it.** The host was on `powersave` when this work started
and is on `performance` now, and the change happened somewhere inside this window. Figures either
side of that change are not comparable and a ratio must not be computed across it.

## What was changed as a result

`benchmark-report/quic/lib.sh` gained a per-cell gate rather than a per-sweep one:

- `require_quiet` runs **before every cell** and requires both that no foreign container exists
  (anything other than the unrelated, always-present `claudecodeui`) and at least 85% CPU idle.
- `await_quiet` blocks between cells rather than measuring through a neighbour.
- `run_client` samples the foreign-container count **throughout** the measured window and tags the
  row `CONTENDED`, so a neighbour that starts mid-cell is recorded rather than inferred afterwards.
- Every row now carries `srvMhz` and `cliMhz` separately, sampled during the window, because the
  two sides are pinned to different physical cores and a one-sided clock difference would otherwise
  look like a protocol difference.
- Every sweep header records the governor, so a run under `powersave` can never be silently
  compared with one under `performance`.

## Raw data

- `benchmark-report/quic/logs/q1-DISCARDED-contended.tsv` -- the withdrawn first attempt, kept
  because the retraction is worth more than the numbers were. The file has no `contended` column;
  that column exists precisely because this run had no way to record it.

## Related

- [Q0](Q0-quic-harness-design.md) -- the harness and its design decisions
- [D3](D3-interleaved-transport-comparison.md) -- the branch's other retracted-then-redone comparison
