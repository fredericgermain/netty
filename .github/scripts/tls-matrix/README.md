# TLS benchmark matrix

Runs netty's existing `microbench` TLS benchmarks inside a set of container images and checks that
each cell really produced numbers.

The Linux native artifacts are built on CentOS and tested on Ubuntu. Nothing in the ordinary build
measures, or even exercises, a TLS handshake on musl, on a vendor JDK image, or on aarch64. These
scripts do, using the shaded `microbenchmarks.jar` the `benchmark-jar` profile already produces --
no benchmark code of their own.

## Two modes

| mode | JMH settings | ~time per cell | purpose |
|---|---|---|---|
| `gate` | `-f 1 -wi 1 -i 2` | 1-2 min | must complete and return finite scores. Run this before a release. |
| `insight` | `-f 3 -wi 5 -i 10` | tens of min | the numbers worth reading. Manual or nightly. |

The gate is the point. `microbench` is in no CI workflow today, so a benchmark that only measures
guards nothing.

## Running it

```sh
# once: install the reactor, then build one jar per tcnative flavour
./mvnw -pl microbench -am install -DskipTests=true
./mvnw -pl microbench -Pbenchmark-jar package -DskipTests=true \
       -Dtcnative.artifactId=netty-tcnative-boringssl-static
cp microbench/target/microbenchmarks.jar /tmp/mb-boringssl.jar

.github/scripts/tls-matrix/matrix.sh --jar-boringssl /tmp/mb-boringssl.jar --dry-run
.github/scripts/tls-matrix/matrix.sh --jar-boringssl /tmp/mb-boringssl.jar --out ./results
```

### Which tcnative is under test

By default the jar shades whatever `${tcnative.version}` resolves to, which is the **released**
artifact from Maven Central. That is the right default -- it is what users actually get -- but it
means the Alpine boringssl cells stay red for as long as a musl defect is unfixed upstream, and
that the harness cannot show a candidate fix working.

netty already carries a `boringssl-snapshot` profile that points `tcnative.version` at
`2.0.82.Final-SNAPSHOT` and adds the Central Portal Snapshots repository, so testing against
upstream's latest needs no credentials and no local build:

```sh
./mvnw -pl microbench -Pbenchmark-jar,boringssl-snapshot package -DskipTests=true \
       -Dtcnative.classifier=linux-x86_64
```

Pin the timestamped version rather than `-SNAPSHOT` if the numbers need to stay comparable: that
repository prunes old builds, so cache the jars somewhere durable for anything long-lived.

To test a tcnative you built yourself, point at it with `-Dtcnative.version`:

```sh
# in the netty-tcnative checkout
./mvnw -pl openssl-dynamic,boringssl-static install -DskipTests=true

# in netty
./mvnw -pl microbench -Pbenchmark-jar package -DskipTests=true \
       -Dtcnative.artifactId=netty-tcnative-boringssl-static \
       -Dtcnative.version=2.0.82.Final-SNAPSHOT
```

`tcnativeVersion` in every result row records what the image actually loaded, so a released run and
a patched run can be compared directly rather than taken on trust.

Architecture is not an axis. Emulated timings are noise, so aarch64 numbers come from running the
same script on an aarch64 host; every result row is stamped with `host`, `hostArch`, `arch` and
`libc`, so the two sets concatenate into one dataset.

## Reading the numbers

`aggregate.py` merges the jsonl from any number of hosts into a coverage table and a score table:

```sh
python3 .github/scripts/tls-matrix/aggregate.py results/ --out report.md
```

**Gate-mode scores are not comparable.** With `-f 1 -wi 1 -i 2` and other work on the machine, the
same cell has been observed at 1891 and 18797 us/op in two consecutive runs -- a 10x swing on an
identical configuration. Gate mode answers "did this complete and return finite numbers", nothing
more. Use `--mode insight` on an otherwise idle machine for anything you intend to read, compare or
quote.

## Why each image is in the set

| image | why |
|---|---|
| `eclipse-temurin:21-jdk` | glibc control -- the libc everything is built and tested against |
| `eclipse-temurin:21-jdk-alpine` | musl, on an Alpine JDK image that does ship libgcc |
| `amazoncorretto:21-alpine` | musl with **no** libgcc package, where an artifact that leans on `libgcc_s.so.1` stops loading |

## What the gate checks, and why each check exists

`tag_results.py` decides pass/fail. Every check below is there because something actually slipped
past a weaker one.

- **The JMH result file parses and holds at least `--expect` results.** JMH exits **0** and writes
  an empty array `[]` when every benchmark fails to initialize. A caller trusting the exit status
  reports success having measured nothing.
- **`--expect` is the number of parameter combinations, not 1.** A cell where tcnative crashes the
  JVM still returns the JDK row and still exits 0. "At least one result" would pass it.
- **Every score is finite and strictly positive.**
- **The loaded tcnative matches what was requested**, via `SSL.versionString()` in a `jshell`
  preflight. Otherwise a run labelled BoringSSL can quietly be OpenSSL, or nothing at all.
- **Skipped cells are listed.** Silent truncation of a matrix reads as "we covered everything".
- **The failure *mechanism* is named**, not just the verdict, in `failureMode` on every row and in
  the run output. Two very different things both end as FAIL and readers will otherwise conflate
  them:

  | `failureMode` | what happened | catchable by the application? |
  |---|---|---|
  | `jvm-crash` | a constructor in `.init_array` died during `dlopen`; `crashFrame` names it | **no** -- SIGSEGV inside `JVM_LoadLibrary` |
  | `library-load` | an ordinary `dlopen` failure, e.g. an unresolvable `DT_NEEDED` | yes -- `UnsatisfiedLinkError` |

  `jvm-crash` is the one case musl's deferred-relocation behaviour does not cover: an unresolved
  symbol reached from an init constructor takes the process down at load rather than waiting to be
  called. Released netty-tcnative on Alpine aarch64 does exactly this, in `init_have_lse_atomics`
  via `__getauxval`.

## In CI

`.github/workflows/ci-tls-matrix.yml` runs this on native x86_64 and aarch64 runners: `gate` mode
on push and pull request, `insight` mode on a weekly schedule and on demand. Results are uploaded
as artifacts even when the matrix fails, because the jsonl and the run log are how you tell a
regression from an image that changed underneath you.

Every cell runs one TLS 1.2 suite and one TLS 1.3 suite. They are genuinely different code paths --
in TLS 1.3 the client reaches FINISHED before the server is done, and NewSessionTicket follows the
handshake proper -- so a gate that only ran 1.2 would miss half of what applications negotiate.

## Findings from the first runs

Kept here because they are the evidence for the checks above.

1. **The shaded benchmark jar could not run any SSL benchmark.** `AbstractSslEngineBenchmark` and
   `AbstractSslHandlerBenchmark` resolved their key material with
   `new File(getClass().getResource("test.crt").getFile())`, which inside a jar yields
   `file:/…/microbenchmarks.jar!/…/test.crt` -- not a path. Fixed by reading the resources as
   streams.
2. **JMH's exit status is not evidence.** See above; this is why `tag_results.py` exists at all.
3. **The SSL contexts were built eagerly for every provider.** They were enum field initialisers,
   so all constants were constructed in `<clinit>` and `-p sslProvider=JDK` still called
   `OpenSsl.ensureAvailability()`. The JDK provider could not be measured on any image without a
   working tcnative -- exactly where you most want to measure it. Fixed by building them on first
   use.
4. **netty-tcnative openssl-dynamic needs system packages** that a stock JDK image need not have:
   `libssl`, `libcrypto` and `libapr`. Alpine ships the first two but not APR, so the cell dies
   with `Error loading shared library libapr-1.so.0`. `run.sh` installs them per flavour;
   boringssl-static needs nothing.
5. **openssl-dynamic publishes no `linux-aarch_64` classifier**, only `linux-aarch_64-fedora`. The
   openssl cells are therefore x86_64-only unless the fedora classifier is used.
6. **TLS 1.3 was not benchmarked at all**, on any provider: both base classes pinned the engine
   to `TLSv1.2`. Enabling it needed more than a parameter. The engine benchmarks drove the
   handshake in lock step and stopped when both sides reported `FINISHED`, which is the TLS 1.2
   flow; in TLS 1.3 the client reports `FINISHED` while it still has its own Finished to send, so
   the server never completes. They also reused handshake buffers across invocations, and TLS 1.3's
   post-handshake NewSessionTicket left bytes behind that the next invocation read as a new stream.
   Both fixed; the handler benchmarks, which go through `SslHandler`, were already correct.
7. **Released netty-tcnative 2.0.81 fails on Alpine aarch64, in two different ways depending on
   the image.** On `eclipse-temurin:21-jdk-alpine`, which ships libgcc, boringssl-static loads and
   then takes the JVM down:
   `# C [libnetty_tcnative_linux_aarch_64…so+0x2476c] init_have_lse_atomics+0xc` -- libgcc's
   AArch64 outline-atomics probe calling `__getauxval` from an ELF init constructor, a symbol musl
   does not export (netty-tcnative issue #907). It is a hard crash rather than an
   `UnsatisfiedLinkError`, so an application cannot catch it and fall back. On
   `amazoncorretto:21-alpine`, which ships no libgcc, the same artifact does not load at all:
   `Failed to load any of the given libraries`. The gate catches both; a load-only check on a
   glibc host catches neither.

   Measured against the **released** artifact. Re-running the identical matrix against upstream's
   post-merge snapshot -- `netty-tcnative-boringssl-static:2.0.82.Final-20260819.163017-9`, which
   carries the #997 fix -- turns both cells green, which is the harness demonstrating a fix rather
   than only detecting a defect:

   | image | released 2.0.81 | patched 2.0.82 snapshot |
   |---|---|---|
   | `eclipse-temurin:21-jdk-alpine` | SIGSEGV in `init_have_lse_atomics` | 4/4 results, PASS |
   | `amazoncorretto:21-alpine` | `Failed to load any of the given libraries` | 4/4 results, PASS |

   The patched artifact's `DT_NEEDED` is `librt.so.1 libpthread.so.0 libdl.so.2 libc.so.6` -- every
   one a musl-reserved stem, satisfied by the loader itself, never a file lookup.

## Portability notes

Both scripts run on Linux and macOS hosts, which took two fixes worth remembering:

- macOS ships bash 3.2, where expanding an empty array under `set -u` is an "unbound variable"
  error rather than nothing. `run.sh` uses plain strings for optional argument lists; `matrix.sh`
  guards every array expansion on `${#arr[@]}`.
- On macOS `mktemp -d` returns a path under `/var/folders`, which Colima does not share with its
  VM. A container writing there succeeds, the bytes never reach the host, and the results come back
  empty with no error anywhere. `run.sh` puts its scratch directory under `--out` instead.
