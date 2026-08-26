# B. QUIC musl fix

**Confidence:** SOLID
**Date:** 2026-08-19 22:34:22 +0100 (commit date of `50d78dbc88`)
**Question:** can the tcnative #997 musl-compatibility approach be ported to `codec-native-quic`, and
does the resulting artifact load on Alpine?

## Configuration

Branch `quic-musl-compat`, single commit `50d78dbc88906e7371b32abcabac3b4795e39108`, "Make the Linux
codec-native-quic artifacts loadable on musl (Alpine)". Built through netty's own docker-compose
toolchain (`docker/Dockerfile.centos7` for x86_64, `docker/Dockerfile.cross_compile_aarch64` for
aarch64), both of which this commit modifies to install `patchelf`.

Verification harness: `.github/scripts/musl-verify/verify.sh` plus
`.github/scripts/musl-verify/QuicMuslCheck.java`, a QUIC client and server in one JVM, with levels
`load` / `init` / `handshake`. Wired into `.github/workflows/ci-verify-musl.yml`.

## Result

Commit stat, verified with `git show --stat quic-musl-compat`:

```
 .github/scripts/musl-verify/QuicMuslCheck.java | 309 +++++++++++++++++++++++
 .github/scripts/musl-verify/README.md          |  73 ++++++
 .github/scripts/musl-verify/verify.sh          | 224 +++++++++++++++++
 .github/workflows/ci-verify-musl.yml           | 159 ++++++++++++
 codec-native-quic/pom.xml                      | 101 +++++++-
 codec-native-quic/src/main/c/musl_compat.c     | 336 +++++++++++++++++++++++++
 docker/Dockerfile.centos7                      |  15 ++
 docker/Dockerfile.cross_compile_aarch64        |  15 ++
 docker/docker-compose.centos-7.111.yaml        |   3 +
 docker/docker-compose.centos-7.cross.yaml      |   5 +
 docker/docker-compose.yaml                     |   7 +
 11 files changed, 1245 insertions(+), 2 deletions(-)
```

11 files, +1245 lines, `QuicMuslCheck.java` 309 lines -- all three figures confirmed.

`musl_compat.c` contents, confirmed by reading the file out of the commit:

- **21 weak fallbacks.** `NETTY_MUSL_COMPAT` is `__attribute__((weak, visibility("default")))` and
  appears 22 times, once as the `#define` and 21 times as a definition: `open64`, `openat64`,
  `lseek64`, `pread64`, `pwrite64`, `sendfile64`, `ftruncate64`, `stat64`, `fstat64`, `lstat64`,
  `fstatat64`, `__xstat64`, `__fxstat64`, `__lxstat64`, `__fxstatat64`, `__getauxval`, `__res_init`
  and the remainder.
- **Guarded `#ifdef __linux__` then `#ifdef __GLIBC__`**, in that order, with a comment explaining
  that inverting the inner guard would compile the definitions out of exactly the artifacts that need
  them.
- **Stat shims implemented via raw syscalls.** `syscall(SYS_newfstatat, dirfd, path, buf, flags)`,
  because glibc 2.17's `libc_nonshared.a` stubs call `__xstat`, which musl does not have. The comment
  names `SYS_newfstatat` and `SYS_fstat` as the two available on both architectures.

`codec-native-quic/pom.xml`, confirmed:

- static libstdc++/libgcc link flags, with a note that they must be spelled `-l:` and never
  `-static-libgcc` because GNU libtool drops the latter
- a `maven-antrun-plugin` patchelf step bound to **`process-test-resources`** with a fileset and a
  `<resourcecount refid="nativeLibToPatch" count="1" />` guard, plus a `patchelf`-on-PATH
  availability check that fails the build with a message naming both Dockerfiles

Verified from source on both architectures. **Deliberately unpushed, PR never opened.**

Two build bugs found and fixed on the way, both worth an article beat:

- patchelf was initially bound to `process-classes`, but hawtjni 1.18 binds its `build` goal to
  `generate-test-resources`, so the `.so` did not exist yet and the step silently patched nothing.
  The pom comment at line 1028 records exactly this.
- the hardcoded `.so` path was wrong because hawtjni nests under `META-INF/native/linux64/`. The pom
  comment records this too, and says the `resourcecount` guard is there to keep a future layout
  change from turning the step back into a silent no-op.

**Upgraded from RECALLED to SOLID.** Every structural claim above -- commit hash, file count, line
count, the 21 weak fallbacks, the guard nesting, the raw-syscall stat shims, the patchelf phase and
its guard -- was read back out of `quic-musl-compat` and matches.

## Reading

Establishes that the fix exists, is complete, and that its two subtle build bugs are documented in
the pom where the next person will find them. The `resourcecount count="1"` guard is the interesting
engineering detail: both bugs had the same failure mode, a build step that succeeds while doing
nothing, and the guard converts that into a build failure.

Does **not** establish that the artifact *runs*. The claim "verified from source on both
architectures" is a source review, and `QuicMuslCheck.java` exists, but **no run log from
`verify.sh` or `ci-verify-musl.yml` is committed anywhere in this branch**. There is no evidence in
`benchmark-report/` that the `load` / `init` / `handshake` levels were ever executed and passed.

Does **not** establish any performance figure. Nothing in Part B is a measurement.

## Raw data

- Branch `quic-musl-compat` at `50d78dbc88`, in this repository. Read with
  `git show quic-musl-compat:codec-native-quic/src/main/c/musl_compat.c` and
  `git show --stat quic-musl-compat`.
- `.github/scripts/musl-verify/README.md` on that branch, 73 lines, describes the verification
  levels.
- **Missing:** any output from `verify.sh`. **Missing:** any CI run of `ci-verify-musl.yml`.
- None of these files exist on `worktree-tls-matrix`; they are only on `quic-musl-compat`.

## Caveats

- **Deliberately unpushed. No PR opened.** The branch lives only in this local checkout. There is no
  fork remote to push to; `origin` points at upstream `netty/netty`.
- No execution evidence, only source evidence. The "verified on both architectures" claim needs a
  committed `verify.sh` transcript before it is publishable.
- Single commit, never reviewed by anyone.
- The upstream approach this ports (tcnative #997) is itself only in 2.0.82-SNAPSHOT, not a release.

## Related

- [A2](A2-tcnative-2081-alpine-both-arches.md) -- the same musl load failure in tcnative
- [A10](A10-patched-tcnative-matrix-gate.md) -- the tcnative side of the fix, with execution evidence
