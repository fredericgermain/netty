# E1. What the benchmark host's cooling actually does

**Confidence:** SOLID for the fan and thermal-mode measurements; the core-count ceiling was never
completed.
**Date:** 2026-08-27 / 2026-08-28
**Question:** the host throttled to 100 C during a sweep. Is the cooling faulty, or is this chassis
simply unable to sustain the load, and what is the right clock policy to benchmark under?

## Why it matters

Three separate measurement corruptions on this branch trace back to CPU clock policy: a 36%
throughput swing between runs of the same cell under the stock governor, a QUIC sweep disqualified by
thermal throttling, and a musl-vs-glibc comparison invalidated by an unpinned clock. The host is a
laptop, so this is not incidental.

## Hardware

Dell **XPS 15 9500**, Intel **i5-10300H** (H-series mobile), 4 physical cores / 8 threads, 2.5 GHz
base, 4.5 GHz max. Two fans, rated 4800 RPM. Trip point `high = crit = 100 C`. Ambient during these
tests **24 C** (measured, user-supplied).

## The fans work

Full-load ramp under the stock `Balanced` thermal profile:

| elapsed | package | fan1 | fan2 | throttling |
|---|---|---|---|---|
| idle | 51 C | 0 | 0 | no |
| +6 s | 86 C | **0** | **0** | no |
| +12 s | 91 C | **0** | **0** | no |
| +18 s | 94 C | **0** | **0** | no |
| +24 s | 97 C | 1261 | 0 | no |
| +30 s | **100 C** | 2744 | 3081 | **starts** |
| +30 s to +120 s | pinned 100 C | ~3235 | ~3510 | ~9,400 events |
| cool +36 s | 63 C | 1664 | 0 | stopped |

They ramp from 0 to ~3235/3510 RPM and pull the package from 100 C to 63 C in 36 seconds once load
stops. **Not a dust or bearing fault.**

Two observations that matter more than the verdict:

- **The stock curve does nothing until 97 C.** Both fans sit at 0 RPM through 86, 91 and 94 C. By the
  time they start, the package is already at its trip point.
- **They never reach their rating.** Peak observed is ~3240/3510 against 4800. During *cooldown* they
  briefly ran higher (3485/3744) than under load, which points at a firmware policy rather than a
  mechanical ceiling.

## Dell thermal mode changes when, not how hard

Set with `smbios-thermal-ctl --set-thermal-mode=performance` from `libsmbios-bin`. Takes effect
immediately, **no reboot**.

| package | `Balanced` | `Performance` |
|---|---|---|
| 86 C | 0 RPM | -- |
| 90 C | -- | **2812 / 3120 RPM** |
| 94 C | 0 RPM | -- |
| 97 C | fan1 starts (1261) | -- |
| 100 C | 3233 / 3507 | 3225 / 3513 |

**[UNCERTAIN]** The 90 C onset is an upper bound: the package was already 90 C at the first sample
three seconds in, so the fans may have started earlier. This chassis heats extremely fast.

Peak speed is unchanged, so the mode moves the curve earlier without raising its ceiling.

## Fan RPM cannot be set directly on this model

| interface | result |
|---|---|
| `pwm1`/`pwm2` via `dell_smm_hwmon` | writes accepted, silently ignored; values stay 0 |
| module `force` / `restricted` params | **absent**; this kernel build exposes only `power_status` |
| `/proc/i8k` | **`-r--r--r--`**, read-only; `i8kctl fan 2 2` returns `0 0` |
| `smbios-thermal-ctl` | works, but sets the *mode*, not the RPM |

Dell moved fan control to the EC on this generation. The thermal mode is the only available lever,
which is why `libsmbios-bin` is a hard dependency of the `benchmark_env` Ansible role.

## The clock policy this produced

| setting | behaviour |
|---|---|
| `powersave` (the DYNAMIC governor, despite the name) | ranges 800-4500 MHz; **36% throughput swing** between runs of the same cell |
| `performance`, uncapped | reaches **100 C in 30 s**, then throttles continuously; up to **533 events** in one measured cell |
| `performance`, `min=max=62%` | **2593 MHz mean, 62 C, zero throttle events**, same throughput as `powersave` |

**Neither stock governor is correct on a mobile CPU.** The capped configuration gives `powersave`'s
throughput with a stable clock and no throttling.

**Setting `max` alone is not enough.** With `max_perf_pct=62` but `min_perf_pct=17` still in place,
`intel_pstate` remains free to scale below the cap: a run taken that way spanned **65,767-101,292
req/s**, a 54% spread, while the recorded per-side frequency moved only 2528-2752 MHz. The floor is
what pins it.

## Core-to-core thermal asymmetry

Throttle counts diverge enormously across cores on the same die. In one uncapped sweep:

| core0 | core1 | core2 | core3 |
|---|---|---|---|
| 6,103 | 23,344 | **31** | **50,292** |

A factor of ~1,600 between core2 and core3. This is presumably placement relative to the heat pipes.
It matters because the pinning used for the corrected runs put the **server on cores 0,1 and the
client on 2,3**, which straddles the coolest and the hottest core rather than balancing them.

## What was NOT established

**[UNCERTAIN] The throttle-free core count.** Two attempts at the sweep failed, both for
methodological reasons rather than hardware ones:

1. The first ran with the stock `Balanced` profile, so it measured the lazy fan curve rather than the
   chassis.
2. The second started on a machine still hot from the first and reported 92 C for a *single* core,
   which is nonsense. It needed a cool-down gate between levels.

What is known: at the capped 62% setting, 8 threads showed **zero** throttle events across whole
sweeps, so the cap already keeps the machine inside its envelope. And even with the aggressive fan
curve, 8 threads at *full* turbo still pin the package at 100 C, which is a chassis limit rather than
a cooling fault.

**[UNCERTAIN] The iowait-boost interaction.** io_uring marks completion waiters `in_iowait` and
`intel_pstate` feeds iowait into its boost heuristic, so two transports could still drive the clock
differently even under a pinned policy. Recording per-side mean frequency per cell is what would
detect it; nothing has.

## Operational traps hit while measuring this

- **`pkill -f` on a renamed process does not work through `taskset`.** Burn loops launched as
  `exec -a fanburn taskset -c N sh -c '...'` rename *taskset*, which then `exec`s `sh` and loses the
  name. 31 loops survived a killed sweep and kept the machine at load 29. Use a literal marker
  argument (`sh -c '...' MARKER`) that survives into the final process instead.
- **`timeout N docker run ...` does not stop the container.** It kills the local client while the
  container keeps running detached, holding its name and port. One such orphan blocked a later sweep
  from starting, and the sweep's own quiet-gate is what caught it.

## Raw data and scripts

- `benchmark-report/scripts/thermal/fantest.sh` -- full-load ramp with fan and throttle sampling
- `benchmark-report/scripts/thermal/fanonset.sh` -- fan onset temperature, for comparing thermal modes
- `benchmark-report/scripts/thermal/coresweep.sh`, `coresweep2.sh` -- the two incomplete core-count attempts
- `benchmark-report/scripts/bench-env.sh` -- the resulting start/stop/check tooling, also shipped as
  the `benchmark_env` Ansible role (`roles/benchmark_env` in the manergi/ansible repo, unit name
  `bench-tuning.service`)

## Related

- [D19](D19-tls-warmup-and-ordering.md) -- the run whose frequency and temperature logging first
  showed the clock moving
- [Q1](Q1-quic-vs-tcp-tls.md) -- the sweep disqualified by thermal throttling after the governor was
  set to uncapped `performance`
