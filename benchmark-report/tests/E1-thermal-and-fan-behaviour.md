# E1. What the benchmark host's cooling actually does

**Confidence:** SOLID. **Moved out of this repository.**

**Question:** the host throttled to 100 C during a sweep. Is the cooling faulty, or is this chassis
simply unable to sustain the load, and what is the right clock policy to benchmark under?

## Where it lives now

`~/workspaces/fred/dell-xps-9500-bench-rig`, its own repository.

The measurements are about a Dell XPS 15 9500 rather than about netty, and they apply to anything
benchmarked on this host, so they were extracted. That repository holds the merged write-up, the
`csv` and raw logs, the fan and core sweeps, and `bench-tuning.sh` / `bench-tuning.service`. Its
`PROVENANCE.md` records the commit here that it was taken from.

## What it concluded, in one paragraph

There is no throttle-free core count at unrestricted turbo -- **even one core throttles**, because a
single busy core boosts toward 4.5 GHz and single-core turbo is a high-voltage state. The limit is
clock, not core count. The fans are not at fault: they ramp to ~3240/3510 RPM and pull the package
from 100 C to 63 C in 36 seconds, but a thin 15-inch chassis cannot dissipate sustained all-core
turbo. The policy that follows is `performance` governor with `min_perf_pct == max_perf_pct == 62`,
near 2800 MHz, where all 8 cores run with **zero** throttling. Capping `max` alone is not enough:
with the floor left at 17 a run spanned 65,767-101,292 req/s, a 54% spread.

## Why this stub is kept

`TESTS.md` indexes E1, several findings cite the capped clock as a scope limit, and
`scripts/musl-alloc/alloc-test-6cell.sh` gates on `bench-tuning.service`. A dangling index entry
would be worse than a pointer.

## Related

- [D19](D19-tls-warmup-and-ordering.md) -- the run whose frequency and temperature logging first
  showed the clock moving
- [Q1](Q1-quic-vs-tcp-tls.md) -- the sweep disqualified by thermal throttling after the governor was
  set to uncapped `performance`
