# D19. TLS warm-up and TLS ordering

**Confidence:** SOLID for the trend question, UNCERTAIN for the ordering
**Date:** 2026-08-26, after 07:41 BST (script committed at `94880d4a95`, "Add mechanism-discriminator
and TLS warm-up sweep scripts")
**Question:** io_uring's TLS throughput appeared to climb across fresh JVMs. Is that a real warm-up
effect, or machine state?

## Configuration

Driver `loadtest/scripts/thor-tlswarm.sh`. Jar `loadtest-pin.jar`, image
`eclipse-temurin:21-jdk-alpine`.

- 10,000 connections, 10 s, 1 KB payload, **`--tls=openssl`** (tcnative/BoringSSL), closed loop
- **Ten consecutive fresh-JVM rounds per transport**, io_uring first then epoll. Not interleaved.
- `--threads=4`, `--backlog=8192`
- **Old (SMT-sibling) pinning, deliberately**: server `--cpuset-cpus=0-3`, client
  `--cpuset-cpus=4-7`. The script header says why: the trend under investigation was measured under
  the old pinning, and reproducing an anomaly means reproducing its conditions.
- **No `--ulimit memlock=-1`** on either container, unlike every other corrected-era sweep
- Per round, sampled from the host: `cpu0` `scaling_cur_freq`, the maximum
  `/sys/class/thermal/thermal_zone*/temp`, and `load1m` from `/proc/loadavg`

## Result

| | rounds | median |
|---|---|---|
| io_uring TLS | 84,074 - 115,974 | **110,585** |
| epoll TLS | 72,755 - 97,351 | 94,681 |

**No warm-up trend.** Round 1 is among the highest io_uring rounds of the ten, and the sequence has
no monotone component: 115,260, 115,974, 102,510, 109,626, 105,812, 84,074, 112,307, 111,544,
111,966, 95,151.

The earlier five-round climb (70,442 to 115,189) does not reproduce and was machine state.

io_uring is about **17%** faster, with 9 of 10 rounds above epoll's median.

Verbatim from `benchmark-report/logs/tlswarm.log`:

```
ur-01  rps=115260 rampConnPerSec=2490 freqKHz=3199995 tempMilliC=67000 load1m=13.75
ur-02  rps=115974 rampConnPerSec=2481 freqKHz=3600504 tempMilliC=88000 load1m=13.81
ur-03  rps=102510 rampConnPerSec=2245 freqKHz=3200072 tempMilliC=74000 load1m=14.28
ur-04  rps=109626 rampConnPerSec=2582 freqKHz=3198267 tempMilliC=73000 load1m=13.98
ur-05  rps=105812 rampConnPerSec=2461 freqKHz=3202394 tempMilliC=73000 load1m=13.84
ur-06  rps=84074  rampConnPerSec=2497 freqKHz=3199992 tempMilliC=72000 load1m=15.08
ur-07  rps=112307 rampConnPerSec=2492 freqKHz=3200005 tempMilliC=71000 load1m=14.57
ur-08  rps=111544 rampConnPerSec=2620 freqKHz=3200079 tempMilliC=71000 load1m=14.05
ur-09  rps=111966 rampConnPerSec=2574 freqKHz=3209335 tempMilliC=73000 load1m=13.68
ur-10  rps=95151  rampConnPerSec=2597 freqKHz=3200008 tempMilliC=73000 load1m=13.77
ep-01  rps=93868  rampConnPerSec=2568 freqKHz=3499149 tempMilliC=83050 load1m=13.96
ep-02  rps=91128  rampConnPerSec=2357 freqKHz=3200021 tempMilliC=74000 load1m=14.77
ep-03  rps=96061  rampConnPerSec=2611 freqKHz=3200106 tempMilliC=73000 load1m=14.38
ep-04  rps=97351  rampConnPerSec=2707 freqKHz=3202743 tempMilliC=72000 load1m=14.25
ep-05  rps=92850  rampConnPerSec=2613 freqKHz=3200038 tempMilliC=74000 load1m=14.28
ep-06  rps=93093  rampConnPerSec=2683 freqKHz=3197066 tempMilliC=74000 load1m=14.57
ep-07  rps=72755  rampConnPerSec=2565 freqKHz=3199832 tempMilliC=75000 load1m=14.09
ep-08  rps=95494  rampConnPerSec=2636 freqKHz=3199984 tempMilliC=76000 load1m=14.50
ep-09  rps=95967  rampConnPerSec=2676 freqKHz=3200009 tempMilliC=72000 load1m=15.03
ep-10  rps=95620  rampConnPerSec=2667 freqKHz=3199873 tempMilliC=72000 load1m=14.20
```

### Three corrections against the log

This test had the most catalogue figures that did not survive re-reading.

**1. The io_uring median was wrong.** The catalogue gives 107,719. The correct median of the ten
io_uring rounds is **110,585**.

Sorted: 84,074 / 95,151 / 102,510 / 105,812 / 109,626 / 111,544 / 111,966 / 112,307 / 115,260 /
115,974. With ten values the median is the mean of the 5th and 6th, `(109,626 + 111,544) / 2 =
110,585`. The published 107,719 is `(105,812 + 109,626) / 2` -- the 4th and 5th, an off-by-one in the
median index. The epoll median, 94,681, is `(93,868 + 95,494) / 2` and is **correct**, so the error
affected one of the two cells only.

Consequence: io_uring's advantage is **+16.8%**, not ~14%. The correction makes the result stronger,
not weaker.

**2. "Round 1 is the highest io_uring round of the ten" is false.** Round 1 is 115,260; round 2 is
115,974 and is higher. Round 1 is the **second**-highest of the ten. The conclusion the claim was
supporting -- that there is no warm-up ramp -- is unaffected and if anything better supported: the
two highest rounds of the ten are the first two.

**3. "Frequency stable at 3.2 GHz and temperature 71-76 C" is false.** Across the twenty rounds:

- frequency is 3.20 GHz on eighteen rounds but **3.60 GHz on `ur-02`** and **3.50 GHz on `ep-01`**
- temperature ranges **67 C to 88 C**, not 71 to 76. `ur-01` is 67 C, `ur-02` is **88 C** and `ep-01`
  is **83 C**

The two frequency excursions are on the two rounds that also carry the two highest temperatures, and
both are the *first* round of their block -- the signature of a cold machine taking turbo and heating
up. That is exactly the machine-state story the test was designed to detect, and it is visible in the
data that was collected for the purpose. The 71-76 C claim as published would have removed the
evidence for the test's own conclusion.

## Reading

Establishes that the warm-up trend is not real. Ten fresh JVMs, no monotone component, the two
highest rounds first. The earlier five-round climb was machine state in one run.

Establishes an io_uring TLS advantage with reasonable confidence for the *direction*: 9 of 10 rounds
above epoll's median, and the medians differ by 17% against within-cell spreads of 38% (io_uring) and
34% (epoll). Consistent with the read-count mechanism in
[D17](D17-mechanism-discriminator.md): TLS at 1 KB is crypto-dominated, so per-read transport
overhead is a much smaller share of the total and io_uring's batching across ten thousand connections
can show.

Does **not** establish the ordering reliably. The twenty rounds were **consecutive per transport
rather than interleaved**, because the question asked was about a within-transport trend. Every other
transport comparison in Part D is interleaved precisely because the machine drifts, and this one is
not. The per-round frequency and temperature logging is what makes the cross-transport comparison
usable at all, and once the excursions above are accounted for it is still ten io_uring rounds run
before ten epoll rounds on a machine with `load1m` between 13.68 and 15.08 throughout.

**Repeat interleaved before publishing the ordering.**

## Raw data

- `benchmark-report/logs/tlswarm.log` -- all twenty rounds with frequency, temperature and load
- `loadtest/scripts/thor-tlswarm.sh` -- the driver, including the reasoning for keeping the old
  pinning
- `benchmark-report/logs/q3.log` -- the source of the withdrawn five-round climb (70,442 / 82,764 /
  111,042 / 115,721 / 115,189, verified present in the `io_uring openssl` rows)

**Verified against `benchmark-report/logs/tlswarm.log`.** Both round spreads and the epoll median
match; the io_uring median, the round-1 claim and the frequency/temperature claim are corrected
above.

### WITHDRAWN

An earlier run showed io_uring's TLS throughput climbing across five fresh JVMs (70,442 then 82,764,
111,042, 115,721, 115,189) and it was treated as a real warm-up effect that blocked any TLS claim. It
does not reproduce. **That was machine state in one run.** The withdrawal stands.

## Caveats

- **Not interleaved.** This is the central caveat and it is not repairable by analysis.
- **Old SMT-sibling pinning**, deliberately, so these numbers are not comparable with
  [D16](D16-pinning-and-cache-ceiling-64kb.md) onward.
- **No `memlock=-1`** on the containers, unlike the other corrected-era sweeps. Nothing here uses
  zero-copy, so it should not matter, but it is a configuration difference.
- Wide spreads: io_uring 84,074 to 115,974 (38%), epoll 72,755 to 97,351 (34%). Ten rounds each is
  what makes the medians usable at all.
- `load1m` sits between 13.68 and 15.08 for the whole run on a 4-core box. Something else was on the
  machine throughout.
- 1 KB payload only. TLS at larger payloads was never measured.
- One cipher and one provider, whatever `--tls=openssl` selects by default.
- Frequency is sampled from `cpu0` only, once per round, *after* the round.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared.

## Related

- [D3](D3-interleaved-transport-comparison.md) -- the interleaved TLS cells that could not resolve
  this
- [D4](D4-q3-cpu-accounting.md) -- the run whose TLS column produced the withdrawn climb
- [D17](D17-mechanism-discriminator.md) -- the read-count mechanism this is consistent with
- [D1](D1-first-10k-connection-runs.md) -- the first observation that io_uring wins with TLS
