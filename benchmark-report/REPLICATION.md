# Replication protocol: the same cells on a second machine

Written before the runs rather than after, because a criterion invented once the numbers are in is
not a criterion.

## Why

`FINDINGS.md` says the loopback result is "the strongest reason yet to repeat the whole io_uring
comparison on a second machine before publishing". Everything on this branch comes from one laptop.
A second machine does not have to be better; it has to be **different silicon**, so that a result
which survives is a property of the transport and one which does not is a property of thor.

## The two machines

| | thor | the second machine |
|---|---|---|
| model | Dell XPS 15 9500 | Dell XPS 13 9380 |
| CPU | i5-10300H, Comet Lake-H, 45 W | i7-8565U, Whiskey Lake-U, 15 W |
| cores | 4 physical / 8 logical | 4 physical / 8 logical |
| memory | 64 GB | 16 GB |
| chassis | 15-inch, two fans | 13-inch, one fan |

Same core count, so the structural limit stays: each side of every comparison gets two physical
cores. The 9380 is **not an upgrade** and is not expected to produce better numbers. It is a
different thermal envelope and a different microarchitecture generation, which is what replication
needs.

## Both machines boot the same USB key

This is the design decision that makes the comparison clean. If thor runs its installed Ubuntu with
a self-built `7.0.14-acpica-acpica` and the 9380 runs a live image's stock kernel, then the machine
and the kernel change together, and the result is uninterpretable. One key, booted on both, holds
the kernel, the userland, the images and the jar fixed by construction. **The only variable left is
the hardware.**

### The historical numbers are not the baseline

Every figure in `FINDINGS.md` was measured on **6.8.0-57-generic**. The USB session will be 7.0.x,
which has send-zc buffer coalescing, send/recv bundles and `IORING_ENTER_NO_IOWAIT` -- the three
features `ENVIRONMENT.md` section 3 names as absent and decisive. So the old numbers cannot serve as
the thor side of this comparison.

The order is therefore:

1. **thor, from the USB.** Re-establish the anchor cells. This is also the io_uring re-run that
   `ENVIRONMENT.md` has been asking for, so it is not extra work.
2. **9380, from the same USB.** The same cells.
3. Compare 2 against 1. The 6.8 figures stay in the documents as history, clearly dated, and are
   never differenced against either.

## The anchor cells

Four, interleaved, five rounds each. Not the whole catalogue: the claims that block the article.

| # | cell | thor on 6.8, for orientation only |
|---|---|---|
| A | TCP echo, 64 KB, 2000 conns, 4 threads, whole-core pinning | epoll 40,630 / io_uring 17,257 (43.2%) |
| B | as A, plus `--rcvbuf-max=512K` and 1 MB `maxCachedBufferCapacity` | io_uring 28,687 (+60.7%), epoll -3.6% |
| C | raw framing, 1 KB and 64 KB, **1 thread, 50 conns**, C client | io_uring 1.11x at both |
| D | TLS, 1 KB, 10k conns | io_uring +16.8% |

Cell D is the stretch: 10k connections is about 20k descriptors per side, and the 9380 has 16 GB
against thor's 64. Validate that it establishes before trusting a number from it, and if it does not,
say so rather than quietly running 2k and calling it D.

Cell C carries the most weight, because it is the cell that inverted the headline and the branch's
open question is which of its four differences from cell A is responsible. Running it on a second
machine does not answer that question, but a C that fails to reproduce would tell us the inversion
was thor-specific, which would be the most important thing this exercise could find.

## The calibration, and how to read it

`scripts/calibrate.sh` runs before and after each machine's set and appends to
`logs/calibration.tsv`. Two anchors: a single-core sha256 over a fixed 256 MiB buffer, and one fixed
cheap network cell. Both run inside the benchmark image.

Read them together:

- **network anchor moves, compute anchor does not** -- the difference is in the kernel network path
  or the stack, not the silicon. Transport ratios remain comparable.
- **both move by the same factor** -- clock and memory speed. Express every cell as a ratio to the
  anchor and the comparison survives.
- **compute anchor moves more than the network anchor** -- the slower machine is bottlenecked
  somewhere other than CPU, which is itself a finding about the cell.

A ratio to the anchor is the number that outlives both machines. An absolute req/s from a 2026
laptop is not comparable to anything.

## What counts as a reproduction

Applying the branch's existing rule on spreads -- if a range overlaps the cell it is compared
against, the difference is not established -- to the **ratio** rather than to the absolute rate:

| outcome | criterion | what it means |
|---|---|---|
| **Reproduced** | the two machines' ratio ranges overlap | the finding is a property of the transport. Publish with both columns. |
| **Direction holds, magnitude differs** | same side of 1.0, ranges do not overlap | publish the direction, give both magnitudes, and do not quote a single figure as "the" ratio |
| **Divergence** | opposite sides of 1.0 | the finding is host-specific. It does not publish as a general claim, and that is a result worth writing up on its own |

Record the outcome per cell before looking at the next cell, so the criterion cannot drift.

## Before measuring on either machine

`scripts/bench-usb.sh check` gates all of this and exits nonzero when the host is not ready. It
refuses outright on a machine with no measured clock cap, rather than borrowing thor's 62%, which is
a property of a 45 W part in a 15-inch chassis and means nothing on a 15 W part in a 13-inch one.

Known prerequisites, each of which has already bitten this work once:

- **Derive the 9380's clock cap** with `sweeps/coresweep3.sh` from the `dell-xps-9500-bench-rig`
  repo, then add it to the table in `bench-usb.sh`. Expect it to be well below 62%.
- **Install `libsmbios-bin` into the USB image.** It is absent from thor as of 2026-11-16, and
  without `smbios-thermal-ctl` both fans stay on the stock curve, which leaves them at 0 RPM until
  about 97 C. The two machines must be in the same thermal mode or they are not comparable.
- **Stop the `adb-relay` container on thor**, or every cell is marked `CONTENDED` and discarded by
  `lib.sh`'s own rule.
- **`somaxconn` to 8192**, which `bench-usb.sh start` does. thor currently sits at 4096, below the
  `SO_BACKLOG` the sweeps request, which truncates the accept queue silently.
- **`RESULTS_DIR` on persistent storage.** Nothing in a RAM-resident session survives a reboot, and
  section 7.3 of `ENVIRONMENT.md` exists because numbers have already reached documents here without
  their raw record.
