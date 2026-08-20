#!/bin/bash
# ----------------------------------------------------------------------------
# Copyright 2026 The Netty Project
#
# The Netty Project licenses this file to you under the Apache License,
# version 2.0 (the "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at:
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
# ----------------------------------------------------------------------------
# Run the microbench TLS benchmarks inside ONE container image and emit tagged results.
#
# The Linux native artifacts are built on CentOS and tested on Ubuntu, so nothing in the ordinary
# build measures -- or even exercises -- a TLS handshake on musl, on a vendor JDK image, or on
# aarch64. This runs the real thing in whichever image it is pointed at. See matrix.sh for the
# set of images, and README.md for why each one is in the set.
#
# usage: run.sh --jar PATH --image IMAGE [options]
#   --jar PATH          shaded microbenchmarks.jar (matrix.sh builds one per tcnative flavour)
#   --image IMAGE       container image to run in, e.g. eclipse-temurin:21-jdk-alpine
#   --tcnative FLAVOUR  boringssl | openssl | none -- what the jar was built with. Decides which
#                       system packages the image needs; `none` means JDK provider only.
#   --mode gate         short run; must complete and produce finite scores  (default)
#   --mode insight      full JMH forks/iterations; the numbers worth reading
#   --bench REGEX       JMH benchmark selector (default SslEngineHandshakeBenchmark)
#   --out DIR           where to write <cell>.jsonl (default ./results)
#   --expect N          fail unless at least N benchmark results come back (default 1)
#   --platform P        docker --platform. Omit to use the host's native arch: emulated timings
#                       are meaningless, so arch is a matter of which host you run on.
#   -p k=v              extra JMH parameter, repeatable
#
# exit: 0 all good / 1 the cell ran but failed a check / 2 usage or setup error
set -u -o pipefail

JAR=""; IMAGE=""; TCNATIVE="none"; MODE="gate"; BENCH="SslEngineHandshakeBenchmark"
OUT="./results"; EXPECT=1; PLATFORM=""; JMH_PARAMS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --jar) JAR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --tcnative) TCNATIVE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --bench) BENCH="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    -p) JMH_PARAMS="$JMH_PARAMS -p $2"; shift 2 ;;
    *) echo "$0: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$JAR" ] && [ -f "$JAR" ] || { echo "$0: --jar must point at an existing jar" >&2; exit 2; }
[ -n "$IMAGE" ] || { echo "$0: --image is required" >&2; exit 2; }

case "$MODE" in
  # Short enough to sit in front of a release, long enough to be a real handshake. The point is
  # that it completes and returns finite numbers, not that the numbers are publication quality.
  gate)    JMH_OPTS="-f 1 -wi 1 -i 2 -w 2s -r 2s -to 120s" ;;
  insight) JMH_OPTS="-f 3 -wi 5 -i 10 -w 2s -r 2s" ;;
  *) echo "$0: --mode must be gate or insight" >&2; exit 2 ;;
esac

# openssl-dynamic links libssl/libcrypto/libapr, none of which a stock JDK image has to have.
# Alpine ships libssl and libcrypto but not APR, so without this the cell dies at library load
# with "Error loading shared library libapr-1.so.0". boringssl-static needs nothing, which is
# most of the point of it.
case "$TCNATIVE" in
  openssl)   PKGS_APK="apr openssl"; PKGS_APT="libapr1 libssl3" ;;
  boringssl) PKGS_APK="";            PKGS_APT="" ;;
  none)      PKGS_APK="";            PKGS_APT="" ;;
  *) echo "$0: --tcnative must be boringssl, openssl or none" >&2; exit 2 ;;
esac

mkdir -p "$OUT" || exit 2
OUT=$(cd "$OUT" && pwd)
JAR=$(cd "$(dirname "$JAR")" && pwd)/$(basename "$JAR")
HERE=$(cd "$(dirname "$0")" && pwd)

CELL="${IMAGE//[:\/]/-}__${TCNATIVE}__${MODE}"

# Under $OUT rather than mktemp -d. On macOS mktemp returns a path under /var/folders, which Colima
# does not share with the VM: the container's writes succeed but land inside the VM and never reach
# the host, so the results come back empty with no error anywhere. $OUT is by definition a path the
# caller can see.
WORK="$OUT/.work.$$"
rm -rf "$WORK" && mkdir -p "$WORK" || exit 2
trap 'rm -rf "$WORK"' EXIT
chmod 777 "$WORK"   # the container writes here as root

# A plain string, not an array: macOS ships bash 3.2, where expanding an empty array under
# `set -u` is an "unbound variable" error. This script has to run on the aarch64 host too.
PLATFORM_ARGS=""
[ -n "$PLATFORM" ] && PLATFORM_ARGS="--platform $PLATFORM"

# Installed the same way in both container invocations below.
INSTALL_PKGS="
  if command -v apk >/dev/null 2>&1; then
    [ -n \"$PKGS_APK\" ] && apk add --no-cache $PKGS_APK >/dev/null 2>&1
  elif [ -n \"$PKGS_APT\" ]; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -qq -y $PKGS_APT >/dev/null 2>&1
  fi
  true
"

echo "=================================================================="
echo " image     : $IMAGE"
echo " tcnative  : $TCNATIVE"
echo " mode      : $MODE"
echo " benchmark : $BENCH"
echo "=================================================================="

# ---------------------------------------------------------------- preflight
# Ask the image what it actually has, before measuring anything. Without this, "OPENSSL was slow"
# and "OPENSSL silently was not OpenSSL at all" look identical in the results. jshell rather than a
# helper class, so the jar under test stays exactly what netty publishes.
docker run --rm $PLATFORM_ARGS -v "$JAR:/app/mb.jar:ro" -v "$WORK:/out" "$IMAGE" sh -c "
  set -u
  $INSTALL_PKGS
  if command -v apk >/dev/null 2>&1; then libc=musl; else libc=glibc; fi
  {
    echo \"arch=\$(uname -m)\"
    echo \"libc=\$libc\"
    echo \"java=\$(java -version 2>&1 | head -1)\"
  } > /out/preflight.txt
  if command -v jshell >/dev/null 2>&1; then
    printf '%s\n' \
      'String s;' \
      'try { s = io.netty.handler.ssl.OpenSsl.isAvailable() ? io.netty.internal.tcnative.SSL.versionString() : (\"unavailable: \" + io.netty.handler.ssl.OpenSsl.unavailabilityCause()); } catch (Throwable t) { s = \"error: \" + t; }' \
      'System.out.println(\"tcnativeVersion=\" + s.replace((char) 10, (char) 32));' \
      '/exit' | jshell --class-path /app/mb.jar -s - 2>/dev/null | grep '^tcnativeVersion=' >> /out/preflight.txt || true
  fi
  # Must end on a success: grep above exits 1 when tcnative is absent, which is the expected state
  # for the JDK-only cells, and would otherwise read as 'the preflight container failed'.
  true
" || { echo "$0: preflight container failed" >&2; exit 2; }

[ -s "$WORK/preflight.txt" ] || { echo "$0: preflight produced nothing" >&2; exit 2; }
sed 's/^/   /' "$WORK/preflight.txt"

# ---------------------------------------------------------------- the benchmark
echo "-- running"
docker run --rm $PLATFORM_ARGS -v "$JAR:/app/mb.jar:ro" -v "$WORK:/out" "$IMAGE" sh -c "
  set -u
  $INSTALL_PKGS
  java -jar /app/mb.jar '$BENCH' $JMH_OPTS $JMH_PARAMS -rf json -rff /out/jmh.json
" 2>&1 | tail -25
RC=${PIPESTATUS[0]}

# ---------------------------------------------------------------- verdict
# JMH exits 0 and writes an empty array when every benchmark fails to initialize, so its exit
# status is not evidence of anything on its own. tag_results.py is where the cell actually passes
# or fails; everything it checks exists because of that.
python3 "$HERE/tag_results.py" \
  --jmh "$WORK/jmh.json" --preflight "$WORK/preflight.txt" \
  --image "$IMAGE" --tcnative "$TCNATIVE" --mode "$MODE" --bench "$BENCH" \
  --expect "$EXPECT" --docker-rc "$RC" \
  --out "$OUT/$CELL.jsonl"
