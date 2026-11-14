# Gate-mode matrix results, aarch64

Raw `matrix.sh` gate output recovered from `~/workspaces/fred/netty-alpine/bench-artifacts`, which is
not a git repository. These files existed in exactly one place until this commit.

## What they are

All 17 files are from **2026-08-20**, host `WDQQWGPC26`, `hostArch: arm64`, `arch: aarch64`,
`libc: musl` -- the aarch64 half of the tcnative matrix, run on the laptop this work started on
rather than on thor. Mode is gate (`-f 1 -wi 1 -i 2`), so the scores carry no error bars and are not
comparable to the `insight/` runs in the sibling directories.

This is the raw record behind [A2](../../tests/A2-tcnative-2081-alpine-both-arches.md), whose aarch64
observations were tagged `[SOLID, RECALLED]` because, in its own words, "that run produced no log
that survives in this branch". It does now.

## The two failure modes, verbatim from the files

Released `boringssl-static` 2.0.81 on aarch64/musl fails **differently per image**, which A2 recorded
as a single `jvm-crash`:

| directory | image | `failureMode` | `crashFrame` |
|---|---|---|---|
| `cmp-released`, `mech` | `eclipse-temurin:21-jdk-alpine` | `jvm-crash` | `# C [libnetty_tcnative_linux_aarch_64….so+0x2476c] init_have_lse_atomics+0xc` |
| `cmp-released`, `mech`, `agg2` | `amazoncorretto:21-alpine` | `library-load` | none |

The crash frame is the libgcc outline-atomics probe A2 names from memory, now machine-recorded.

Patched `2.0.82.Final-SNAPSHOT` clears both images: `cmp-patched` and `patched` report
`tcnativeVersion: BoringSSL` with 4 rows each.

## Directory names

`results`, `results2`, `agg`, `agg2`, `mech`, `patched`, `cmp-released`, `cmp-patched`, `final` are
the original working directory names from the aggregation work. What distinguished one from the next
was not written down, so trust each file's own fields (`ts`, `image`, `tcnative`, `tcnativeVersion`,
`failureMode`) over its directory name.

## The jars these were produced with

Left in `~/workspaces/fred/netty-alpine/bench-artifacts` rather than committed, at 21 MB each:

| jar | how it was built |
|---|---|
| `mb-patched.jar` | `microbench` with `-Pbenchmark-jar,boringssl-snapshot`, resolving `io.netty:netty-tcnative-boringssl-static:2.0.82.Final-SNAPSHOT` |
| `mb-boringssl.jar` | `microbench` with `-Pbenchmark-jar,boringssl-static` against released 2.0.81 |
| `tcn-x86_64.jar` | the patched tcnative artifact itself, `linux-x86_64` classifier |

`mb-patched.jar` is the jar [A10](../../tests/A10-patched-tcnative-matrix-gate.md) names in its
configuration. A10 itself is an x86_64 run on thor and its raw record is `logs/x86run.log`, not these
files.
