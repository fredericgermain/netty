# D18. glibc control

**Confidence:** SOLID
**Date:** 2026-08-26, around 07:51 BST (commit `ee4d2351a2`, "Add stacked-remediation and glibc-control
sweeps")
**Question:** every io_uring number in this branch came from an Alpine/musl container. Does the size
cliff reproduce on glibc?

## Configuration

Driver `loadtest/scripts/thor-glibc.sh`. Jar `loadtest-pin.jar`.

- **Image `eclipse-temurin:21-jdk`** instead of `eclipse-temurin:21-jdk-alpine`. This is the only
  change from the 64 KB baseline.
- **64 KB payload, 2,000 connections, 10 s**, plaintext, closed loop
- **5 rounds**, two cells interleaved per round
- **Corrected whole-core pinning**: server `--cpuset-cpus=0,1,4,5`, client `--cpuset-cpus=2,3,6,7`
- `--threads=4`, `--backlog=8192`, `--tls=none`
- `--network=host`, `seccomp=unconfined`, `nofile=65536:65536`, `memlock=-1`

## Result

epoll 39,149 - 42,217, io_uring 19,155 - 19,893. Same ~48% ratio. **musl is not a factor.**

Verbatim from `benchmark-report/logs/glibc.log`:

```
port=19990 image=eclipse-temurin:21-jdk payload=65536 connections=2000
round  epoll      io_uring
1      39149      19155
2      41742      19534
3      42217      19893
4      40714      19671
5      40976      19529
```

Medians: epoll **40,976**, io_uring **19,534**, ratio **47.7%**.

**Verified against `benchmark-report/logs/glibc.log`.** Both catalogued bounds match exactly, and the
~48% ratio recomputes from the medians.

## Reading

Establishes that the size cliff is not a musl artifact, which is the precondition for reporting any
of Part D as a netty-on-Linux result rather than a netty-on-Alpine result. Without this control,
"reproduces on the JRE image most people run" and "musl-specific" would be indistinguishable, and
they are very different reports.

Also, incidentally, a better-behaved control than its Alpine counterpart. Both cells here are tight
-- epoll spans 7.8% across five rounds and io_uring 3.9% -- where the `ep-new` cell in
[D16](D16-pinning-and-cache-ceiling-64kb.md), the same configuration on Alpine, spans 29%. Its ratio
of 47.7% sits inside the 47-52% band that D16's unstable epoll baseline supports, so the two agree.

Does **not** compare musl against glibc as a performance question. The two runs are hours apart on a
machine with known drift, and no interleaved musl-vs-glibc cell was ever run. The claim is "the cliff
is present on glibc at the same magnitude", not "glibc and musl are equally fast".

Does **not** cover any payload other than 64 KB, or TLS, or any of the remediation levers.

## Raw data

- `benchmark-report/logs/glibc.log` -- five rounds, both cells, with the image name in the header line
- `loadtest/scripts/thor-glibc.sh` -- the driver

The log records only `reqPerSec`. Unlike `pc64.log` and `mech64.log`, this script does not collect
server pool ranges or client CPU counters, so there is no memory or CPU comparison against glibc.

## Caveats

- One image (`eclipse-temurin:21-jdk`). Not tested on a non-Debian glibc base.
- 64 KB and 2,000 connections only. The rest of the payload sweep was never repeated on glibc.
- Plaintext only. No TLS glibc control exists.
- No pool or CPU counters collected, so the memory-churn signature was not checked on glibc.
- Not interleaved with the musl cells, so the two are not directly comparable as absolute numbers.
- Loopback, queue depth 1, kernel 6.8, 4 physical cores shared.
- The JDK build differs between the two images -- `eclipse-temurin:21-jdk` is 21.0.12 and
  `eclipse-temurin:21-jdk-alpine` is 21.0.11, as recorded in the Part A JMH metadata. For a
  transport-level throughput test this is unlikely to matter, but it is another uncontrolled
  difference between the images.

## Related

- [D16](D16-pinning-and-cache-ceiling-64kb.md) -- the same cell on Alpine, both pinnings
- [D17](D17-mechanism-discriminator.md) -- the mechanism, measured on Alpine
- [D21](D21-stacked-remediation.md) -- the remediation, measured on Alpine
