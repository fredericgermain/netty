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

Architecture is not an axis. Emulated timings are noise, so aarch64 numbers come from running the
same script on an aarch64 host; every result row is stamped with `host`, `hostArch`, `arch` and
`libc`, so the two sets concatenate into one dataset.

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
7. **Released netty-tcnative 2.0.81 boringssl-static SIGSEGVs the JVM on Alpine aarch64**:
   `# C [libnetty_tcnative_linux_aarch_64…so+0x2476c] init_have_lse_atomics+0xc`. That is libgcc's
   AArch64 outline-atomics probe calling `__getauxval` from an ELF init constructor, which musl
   does not export -- netty-tcnative issue #907. It is a hard crash rather than an
   `UnsatisfiedLinkError`, so an application cannot catch it and fall back. The gate catches this
   cell; a load-only check on a glibc host does not.

## Portability notes

Both scripts run on Linux and macOS hosts, which took two fixes worth remembering:

- macOS ships bash 3.2, where expanding an empty array under `set -u` is an "unbound variable"
  error rather than nothing. `run.sh` uses plain strings for optional argument lists; `matrix.sh`
  guards every array expansion on `${#arr[@]}`.
- On macOS `mktemp -d` returns a path under `/var/folders`, which Colima does not share with its
  VM. A container writing there succeeds, the bytes never reach the host, and the results come back
  empty with no error anywhere. `run.sh` puts its scratch directory under `--out` instead.
