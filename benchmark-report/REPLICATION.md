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

1. **The 9380 first**, because it is the machine not in use, and because it is where the key own
   problems will surface: the clock cap for it is unmeasured, its QCA6174 wireless has to come up
   unattended, and 16 GB has to hold a RAM-resident root plus the image store. A shake-down run on a
   free machine costs nothing; the same run on thor costs thor.
2. **thor, from the same key.** This re-establishes the anchor cells on a 7.0.x kernel, which is
   also the io_uring re-run `ENVIRONMENT.md` has been asking for, so it is not extra work.
3. Compare the two. The 6.8 figures stay in the documents as history, clearly dated, and are never
   differenced against either.

Order does not affect validity here, which is the point of the single key: the environment is fixed
by construction, so neither machine is privileged by going first. **But the key must not change
between them.** No `apt upgrade`, no image re-pull, no edit to the jar between the two sets. The
calibration anchors are what detect it if something does: an anchor that moves between the two
machines by more than its own spread means the key changed, not the hardware.

### The jar is built once, against a pinned netty

`loadtest/` is a standalone pom rather than a module of the netty reactor, so it compiles against a
**resolved** netty artifact and not against the working tree: `netty.version` is
`4.2.18.Final-SNAPSHOT`. Two consequences worth stating, because both are easy to get wrong.

First, rebasing this branch onto current 4.2 does not change what the jar measures. The jar and the
checkout are independent, and a sweep run from a rebased branch still exercises whatever version the
pom pins.

Second, that version should stay at `4.2.18.Final-SNAPSHOT` for this exercise. The historical cells
were measured against it, so holding it fixed leaves kernel and machine as the only differences.
Bumping netty at the same time would add a third variable to a comparison designed to isolate one,
and "io_uring improved" and "netty changed" would be indistinguishable in the result.

Build it once with the command in `loadtest/README.md`:

    ./mvnw -f loadtest/pom.xml package -Dnative.classifier=linux-x86_64

then put that one file on the key and never rebuild it between machines. `calibrate.sh` reads
`Implementation-Version` out of the jar manifest into every anchor row, so a jar that was swapped
mid-exercise is visible afterwards rather than merely regrettable.

### Deriving the 9380 clock cap, before any cell on it counts

`bench-usb.sh` refuses on that machine until a figure exists, and the figure has to be measured, not
guessed. Run `sweeps/coresweep3.sh` from the `dell-xps-9500-bench-rig` repo, take the highest
percentage whose throttle delta is zero on every core at 8 threads, and add it to the table in
`bench-usb.sh` with the date. Expect well below thor 62%: that figure is a 45 W H-series part in a
15-inch chassis with two fans, and this is a 15 W U-series part in a 13-inch chassis with one.

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

## The key

Built by `scripts/usb-build.sh`, which writes a stock Ubuntu live ISO to the device and adds a
persistent `BENCHDATA` partition beside it.

The image is **`ubuntu-26.04.1-desktop-amd64.iso`**, 6,482,409,472 bytes, sha256
`601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f`, checked against
`releases.ubuntu.com/resolute/SHA256SUMS` on 2026-11-17. Verify any replacement copy the same way
before writing it: a truncated ISO costs a boot cycle on the other machine to discover.

What has to fit beside it, measured rather than estimated:

| on `BENCHDATA` | size |
|---|---|
| `eclipse-temurin:21-jdk` | 729 MB |
| `eclipse-temurin:21-jdk-alpine` | 554 MB |
| `iouring-control:latest` (cell C's client) | 1.29 GB |
| `loadtest.jar` | 22 MB |
| docker graph, once the tars are loaded | roughly the same again |

So about 2.6 GB of image tars, and the graph they unpack into. A 16 GB key clears the script's 8 GB
check with around 9.5 GB for the partition and works; **32 GB is the comfortable size** once the
graph and several rounds of results are on it. Nothing is remastered: a rebuilt squashfs is a second
thing that can silently differ between two boots, and the whole value of one key on two machines is
that the image is byte-identical. Everything variable lives on `BENCHDATA`, where it can be
inspected.

Boot with **`toram systemd.unit=multi-user.target`** on the kernel command line. `toram` makes the
session RAM-resident so no state accumulates between the two machines; `multi-user.target` stops
GNOME ever starting, which matters more than it sounds on a 16 GB machine -- a desktop session is
resident memory, background services and periodic wakeups on the cores under test, and none of it
is doing anything for a benchmark. `BENCHDATA` is then the only thing that persists, which is
deliberate: it holds the raw output, the docker graph and the jar.

### Why the desktop image rather than something smaller

| option | verdict |
|---|---|
| **Ubuntu desktop live** | What study 05 already booted on this 9380 with wi-fi working, so the firmware path is known-good on the exact hardware. Ships NetworkManager, which `usb-setup.sh` targets, and the full `linux-firmware` including the `ath10k` blobs the QCA6174 needs. Booted to `multi-user.target` its size costs RAM for the squashfs and nothing else. |
| **Ubuntu server live** | Saves a few GB and is viable, but uses netplan and systemd-networkd rather than NetworkManager, so the wi-fi path in `usb-setup.sh` would have to be rewritten against `wpa_supplicant`, and its slimmer `linux-firmware` needs checking for `ath10k` rather than assumed. A rewrite of the one component that was singled out as must-work, to save space on a medium that has plenty. |
| **netboot / PXE** | Ruled out. The 9380 has no Ethernet port and PXE cannot join a WPA2 network, so it needs a USB-C dongle and a netboot server. It also defeats the premise: an image fetched at boot is not a frozen environment, and pinning it to make it one is this key with extra steps. |
| **Alpine from RAM** | Ruled out on evidence, 2026-11-16: `apk add libsmbios` installs the shared library and **no binaries**, so `smbios-thermal-ctl` does not exist there. That is the only fan lever this hardware exposes, and the two machines have to be in the same thermal mode to be compared. Alpine stays where it belongs, inside the container images. |

In the session: `sudo /mnt/benchdata/scripts/usb-setup.sh`. It does Wi-Fi first, on purpose --
package installation, result shipping and reaching the machine at all depend on it, and a session
that quietly has no network wastes the boot.

## Wi-Fi is both a prerequisite and a contaminant

**As a prerequisite**: the 9380 carries a Qualcomm Atheros QCA6174 on `ath10k_pci`, whose firmware is
in `linux-firmware` and present on the live image, so this is known to work on that machine. The
failure modes that do bite are elsewhere, and `usb-setup.sh` checks each: a soft rfkill block after
boot, firmware that loaded and then crashed, and a world regulatory domain (`00`) under which most
5 GHz channels are passive-scan only, so association to a 5 GHz AP fails with no obvious error while
2.4 GHz works. Credentials come from `wifi.conf` on the key, written into a NetworkManager keyfile at
mode 600 so the PSK never reaches the process table. The script waits for an actual IPv4 lease rather
than trusting "connected", and stops if there is none.

**As a contaminant**: these cells run on loopback, so the card is not in the data path -- but it is
in the machine, and its firmware wakes periodically to look for roaming candidates. With four
physical cores and both sides of the comparison pinned, there is no spare core for those interrupts
to land on. Measured on thor on 2026-11-16, two seconds of an idle link absorbed **435 received
packets and 5 interrupts**, so a ten-second window takes on roughly two thousand packets of work on
cores that are fully committed.

This is not worth eliminating, because the link has to stay up. It is worth measuring, so
`lib.sh` now records a `wifiDelta` column per cell as `irq/rx/tx`, on the same principle as the
throttle delta: a cumulative count says the card is sometimes busy, a delta across one cell says
that cell was disturbed. Mitigations applied by `usb-setup.sh` are power save off at both the
NetworkManager and the driver level, a pinned BSSID if `wifi.conf` sets one so the card does not roam
mid-sweep, and the card interrupt steered onto the client cpus -- mitigation rather than a fix, since
the client is merely the less sensitive half.

Results ship **between rounds, never inside a measured window.**

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
  their raw record. `usb-setup.sh` points it at `BENCHDATA/results`, on the key itself.
- **A cell whose `wifiDelta` is far above the others is suspect**, and should be re-run rather than
  averaged in with a footnote.
