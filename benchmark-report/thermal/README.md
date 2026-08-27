# Thermal and clock behaviour of the benchmark host

Why this exists: every performance number on this branch was measured on one laptop, and this
directory establishes what that laptop can actually sustain. Two of the branch's measurement failures
turned out to be thermal or clock artifacts rather than anything about netty, so the host's envelope
is part of the evidence rather than background detail.

## The host

| | |
|---|---|
| machine | Dell XPS 15 9500 |
| CPU | Intel i5-10300H, 4 physical / 8 logical, 2.5 GHz base, 4.5 GHz max turbo |
| driver | `intel_pstate`, range 800-4500 MHz |
| trip point | `high = crit = 100 C` |
| fans | two, rated 4800 RPM, exposed via `dell_smm_hwmon` |
| ambient during all tests | 24 C |

## Findings

### 1. There is no throttle-free core count at unrestricted turbo

**Even one core throttles.** `csv/core-sweep-performance.csv`:

| cores | peak C | mean MHz | throttle delta | verdict |
|---|---|---|---|---|
| 1 | 91 | 3641 | 1,692 | throttled |
| 2 | 98 | 3323 | 3,900 | throttled |
| 3 | 99 | 3809 | 3,903 | throttled |
| 4 | **100** | 3337 | 2,698 | throttled |
| 6 | **100** | 3300 | 18,604 | throttled |
| 8 | **100** | 3261 | 3,319 | throttled |

A single busy core boosts toward 4.5 GHz with the cap lifted, and single-core turbo is a
high-voltage state. `mean_mhz` averages all eight logical CPUs, so at `cores=1` the mean of 3641
implies the one busy core was near maximum.

**So the limiting variable is clock, not core count.** At the capped 2800 MHz
(`max_perf_pct=62`) all 8 cores run with **zero** throttling, which every TCP and QUIC sweep in this
branch recorded as `0/0/0/0`. Uncapping buys no usable headroom on this chassis; it only moves the
machine into throttling.

That is the justification for the capped clock in `bench-tuning.service`. It is not a compromise on
performance, it is the setting at which the machine is thermally stable at full occupancy.

### 2. The fans work. The chassis is the limit

Worth stating plainly because "it throttled" invites "the fans must be clogged", and that is not what
the data shows. From `csv/fan-ramp-balanced.csv`:

- Fans ramp from 0 to ~3240/3510 RPM under load.
- Once load stops they take the package from **100 C to 63 C in 36 seconds**.

That is a cooling system doing its job. What it cannot do is dissipate sustained all-core turbo in a
thin 15-inch chassis, which is a design envelope rather than a fault.

### 3. Dell's thermal mode measurably changes the fan curve, and persists across reboots

The factory default is `Balanced`, and it is remarkably lazy:

| package temp | Balanced | Performance |
|---|---|---|
| 86 C | fans **0 RPM** | -- |
| 90 C | -- | **2812 / 3120 RPM** |
| 94 C | fans **0 RPM** | -- |
| 97 C | fan1 first moves (1261 RPM) | -- |
| 100 C | 3233 / 3507 | 3225 / 3513 |

Under `Balanced` the fans are still stopped at 94 C, six degrees from the trip point. Under
`Performance` they are at roughly 2800/3100 by 90 C.

Changed with `smbios-thermal-ctl --set-thermal-mode=performance` from `libsmbios-bin`. It takes
effect immediately, **no reboot**, and unlike every other setting here it **survives reboots**
because it lives in firmware.

**[UNCERTAIN]** The 90 C onset is an upper bound, not the onset. The package was already at 90 C at
the first sample three seconds in, so the fans may have started earlier. The chassis heats faster
than the sampling interval could follow.

### 4. Peak fan speed is well below the rating, in both modes

Both modes plateau at ~3240/3510 RPM against a rated **4800**. The mode change moves the onset, not
the ceiling.

Two observations suggest this is policy rather than a mechanical limit. During *cooldown* the fans
were measured at 3485/3744, **higher than at any point under load**. And nothing in software can
raise it: `pwm1`/`pwm2` writes are silently ignored, `/proc/i8k` is read-only, and this kernel's
`dell_smm_hwmon` exposes no `force` parameter. Only the firmware curve is available.

### 5. Core-to-core thermal asymmetry is extreme

During one sweep, cumulative `core_throttle_count` reached **core2 = 31** against **core3 = 50,292**,
a factor of 1,600 on the same die. An earlier boot showed the same pattern: core0 and core2 at 0,
core1 at 9,113, core3 at 22,805.

This matters for pinning. The benchmark convention on this branch is server on physical cores 0 and
1, client on 2 and 3, which straddles the coolest and the hottest core and puts the two sides of
every comparison on thermally unequal hardware.

## The settings, and why they are not permanent

`bench-tuning.service` is committed here. It is **installed but disabled** on the host, applied
manually before a measurement and reverted afterwards, because leaving a machine pinned at 2800 MHz
at idle is not a state anyone wants by default.

    sudo systemctl start bench-tuning     # before a sweep
    sudo systemctl stop bench-tuning      # NOTE: does not revert, see below

It sets the `performance` governor, `min_perf_pct = max_perf_pct = 62`, and opens
`kernel.perf_event_paranoid=1` / `kernel.kptr_restrict=0` for unprivileged profiling.

**Two traps worth knowing.**

`intel_pstate` names are misleading: its `powersave` governor is the **dynamic** one, not a low-power
fixed setting. Pinning the clock requires `performance` **and** `min_perf_pct == max_perf_pct`.
Setting only `max_perf_pct` leaves a floor of 17% and the clock still moves, which is what happened
during the QUIC musl sweep where throughput swung 54% inside a single cell.

The unit is `oneshot` with `RemainAfterExit`, so `stop` marks it inactive but **leaves the settings
applied**. Reverting is a separate step.

## Files

| file | what |
|---|---|
| `csv/fan-ramp-balanced.csv` | full ramp and cooldown under the factory fan curve, 8 threads uncapped |
| `csv/fan-onset-performance.csv` | fan onset under the aggressive curve, for comparison |
| `csv/core-sweep-performance.csv` | 1/2/3/4/6/8 cores at 100%, peak temp and throttle delta |
| `logs/coresweep3.log` | raw output behind the core sweep |
| `logs/coresweep2-invalid.log` | an earlier attempt, kept as a record of the failure below |
| `fantest.sh`, `fanonset.sh`, `coresweep3.sh` | the scripts |
| `bench-tuning.service` | the systemd unit |

**Provenance note**: `fan-ramp-balanced.csv` and `fan-onset-performance.csv` are transcribed from
interactive run output, because those two runs wrote no file on the host. Only
`core-sweep-performance.csv` has a raw log behind it. The scripts are committed either way, so all
three are reproducible.

## Failures worth keeping

**`coresweep2-invalid.log`: a sweep that reported 92 C for a single core.** It started each level on a
machine still hot from the previous level. The fix was a cool-down gate, and the rewritten sweep
records its start temperature per level so the reader can judge for themselves.

**31 burn loops survived a killed run.** They were launched as
`exec -a fanburn taskset -c N sh -c '...'`, which renames `taskset`; `taskset` then `exec`s `sh` and
the name is lost, so `pkill -f fanburn` matched nothing. The fix is a literal marker argument that
survives into the `sh` process. The consequence was not subtle: the machine ran hot and loaded for
some minutes, and any measurement taken in that window would have been contaminated.

**The cool-down gate in the final sweep never met its 55 C target.** `bench-tuning` pins the cores at
2800 MHz even at idle, so the idle floor sits near 56 C. The script was fighting its own tuning. The
proper shape is to release the pin during cool-downs and re-apply it before each burn.
