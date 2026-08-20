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
# Drive run.sh over the environment matrix and summarise.
#
# Architecture is deliberately NOT an axis here: emulated timings are noise, so aarch64 numbers
# come from running this same script on an aarch64 host. tag_results.py stamps every row with the
# host and arch, so the two sets concatenate into one dataset.
#
# usage: matrix.sh [options]
#   --jar-boringssl PATH   shaded jar built with netty-tcnative-boringssl-static
#   --jar-openssl PATH     shaded jar built with netty-tcnative (openssl-dynamic)
#   --mode gate|insight    passed through to run.sh (default gate)
#   --only k=v             restrict the matrix, repeatable: image=, tcnative=
#   --dry-run              list the cells that would run, then stop
#   --out DIR              results directory (default ./results)
#
# Build the jars with, from the repo root:
#   ./mvnw -pl microbench -am install -DskipTests=true
#   ./mvnw -pl microbench -Pbenchmark-jar package -DskipTests=true \
#          -Dtcnative.artifactId=netty-tcnative-boringssl-static
#   cp microbench/target/microbenchmarks.jar /tmp/mb-boringssl.jar
#   ./mvnw -pl microbench -Pbenchmark-jar package -DskipTests=true \
#          -Dtcnative.artifactId=netty-tcnative
#   cp microbench/target/microbenchmarks.jar /tmp/mb-openssl.jar
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
JAR_BORINGSSL=""; JAR_OPENSSL=""; MODE="gate"; OUT="./results"; DRY=0
ONLY_IMAGE=""; ONLY_TCNATIVE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --jar-boringssl) JAR_BORINGSSL="$2"; shift 2 ;;
    --jar-openssl) JAR_OPENSSL="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --only)
      case "$2" in
        image=*)    ONLY_IMAGE="${2#image=}" ;;
        tcnative=*) ONLY_TCNATIVE="${2#tcnative=}" ;;
        *) echo "$0: --only takes image=... or tcnative=..." >&2; exit 2 ;;
      esac; shift 2 ;;
    *) echo "$0: unknown argument $1" >&2; exit 2 ;;
  esac
done

# Why each image is in the set:
#   temurin glibc   the control -- the libc everything is built and tested against today
#   temurin alpine  musl, and the Alpine JDK image that does ship libgcc
#   corretto alpine musl with no libgcc package at all, which is where a Linux native artifact
#                   that leans on libgcc_s.so.1 stops loading. See docs on the musl work.
IMAGES="eclipse-temurin:21-jdk eclipse-temurin:21-jdk-alpine amazoncorretto:21-alpine"

# `none` is the JDK-provider control. It reuses whichever jar is available and installs no system
# packages: with lazily-built SSL contexts it must run even where tcnative cannot load at all.
TCNATIVES="none boringssl openssl"

CELLS=(); SKIPPED=()
for image in $IMAGES; do
  [ -n "$ONLY_IMAGE" ] && [ "$image" != "$ONLY_IMAGE" ] && continue
  for tc in $TCNATIVES; do
    [ -n "$ONLY_TCNATIVE" ] && [ "$tc" != "$ONLY_TCNATIVE" ] && continue
    case "$tc" in
      boringssl) jar="$JAR_BORINGSSL" ;;
      openssl)   jar="$JAR_OPENSSL" ;;
      none)      jar="${JAR_BORINGSSL:-$JAR_OPENSSL}" ;;
    esac
    if [ -z "$jar" ] || [ ! -f "$jar" ]; then
      # Silent truncation of a matrix reads as "we covered everything". Record it instead.
      SKIPPED+=("$image / $tc -- no jar for this flavour")
      continue
    fi
    CELLS+=("$image|$tc|$jar")
  done
done

echo "=================================================================="
echo " cells   : ${#CELLS[@]}"
echo " skipped : ${#SKIPPED[@]}"
echo " mode    : $MODE"
echo "=================================================================="
for c in "${CELLS[@]}"; do echo "   run  ${c%%|*} / $(echo "$c" | cut -d'|' -f2)"; done
for s in "${SKIPPED[@]}"; do echo "   SKIP $s"; done

if [ "$DRY" = "1" ]; then
  echo "(dry run)"
  exit 0
fi
if [ ${#CELLS[@]} -eq 0 ]; then
  echo "$0: nothing to run -- pass --jar-boringssl and/or --jar-openssl" >&2
  exit 2
fi

PASS=0; FAIL=0; FAILED_CELLS=()
for c in "${CELLS[@]}"; do
  image="${c%%|*}"; tc=$(echo "$c" | cut -d'|' -f2); jar=$(echo "$c" | cut -d'|' -f3)
  # The JDK control only measures the JDK provider; the tcnative cells measure both so each run
  # carries its own baseline and the two are comparable without joining across cells.
  if [ "$tc" = "none" ]; then providers="JDK"; expect=1; else providers="JDK,OPENSSL"; expect=2; fi
  echo
  # --expect is the number of provider combinations, not 1. A cell where tcnative crashes the JVM
  # still returns the JDK row, and JMH still exits 0, so a count check of "at least one" would let
  # it through. That is not hypothetical: released tcnative 2.0.81 boringssl-static SIGSEGVs in
  # init_have_lse_atomics on Alpine aarch64, and this is one of the two checks that catches it.
  "$HERE/run.sh" --jar "$jar" --image "$image" --tcnative "$tc" --mode "$MODE" --out "$OUT" \
                 --expect "$expect" \
                 -p "sslProvider=$providers" -p "bufferType=DIRECT" \
                 -p "cipher=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
  if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED_CELLS+=("$image / $tc"); fi
done

echo
echo "=================================================================="
echo " passed  : $PASS"
echo " failed  : $FAIL"
for f in "${FAILED_CELLS[@]:-}"; do [ -n "$f" ] && echo "   FAIL $f"; done
for s in "${SKIPPED[@]:-}"; do [ -n "$s" ] && echo "   SKIP $s"; done
echo " results : $OUT"
echo "=================================================================="
[ "$FAIL" -eq 0 ] || exit 1
