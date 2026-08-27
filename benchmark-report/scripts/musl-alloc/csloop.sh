#!/bin/bash
# csloop -- the feedback loop for musl's context-switch excess.
#
# Symptom under diagnosis: for identical work, a JVM on musl performs roughly 10x the context
# switches of one on glibc, and the futex callers are musl's own __lock / __unlock rather than
# anything the application asked for. Allocation has already been ruled out.
#
# The loop is parameterised over the WORKLOAD precisely so that minimisation is a matter of swapping
# one argument rather than rewriting the harness. That is the whole design: the existing repro is a
# two-container QUIC load test taking about a minute per cell, which is too slow and has too many
# moving parts to bisect against.
#
# Verdict line is machine-readable and comparative: it runs the same workload on musl and on glibc
# and prints the ratio, because the absolute count means nothing on its own. RED means the musl
# excess is present for this workload; GREEN means this workload does NOT reproduce it, which during
# minimisation is the informative outcome.
#
# usage: csloop.sh "<java args after the image>"   e.g.  csloop.sh "-version"
set -u
SECS=${SECS:-5}
THRESH=${THRESH:-3.0}      # musl/glibc ratio above which the symptom is considered present
MUSL=${MUSL:-alpine-jdk-musldbg}
GLIBC=${GLIBC:-eclipse-temurin:21-jdk}
JAR=/tmp/loadtest-published.jar
WORK=${1:?usage: csloop.sh \"<java args>\"}
# Optional second container, for workloads that need a driver. The measured PID is always the
# first container's, so the client never enters the count.
CLIENT=${CLIENT:-}

measure() {  # measure <image> ; echoes context switches over $SECS
  local img=$1
  docker rm -f cs-probe >/dev/null 2>&1
  # --cpuset pinned to the same cores in both cases so scheduling pressure is not a variable.
  docker run -d --rm --name cs-probe --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" sh -c "exec java $WORK" >/dev/null 2>&1
  # Give the JVM time to get past startup: class loading and JIT are themselves lock-heavy and
  # would otherwise dominate a short window and mask the steady-state behaviour.
  if [ -n "$CLIENT" ]; then
    docker rm -f cs-driver >/dev/null 2>&1
    docker run -d --rm --name cs-driver --network=host --cpuset-cpus=2,3,6,7 \
      --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
      -v "$JAR:/app/lt.jar:ro" -v /tmp/probes:/work:ro "$img" sh -c "exec java $CLIENT" >/dev/null 2>&1
  fi
  sleep 6
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' cs-probe 2>/dev/null)
  if [ -z "$pid" ] || [ "$pid" = "0" ]; then echo "DEAD"; docker rm -f cs-probe >/dev/null 2>&1; return; fi
  local cs
  cs=$(sudo -n perf stat -p "$pid" -e context-switches -- sleep "$SECS" 2>&1 \
       | grep context-switches | awk '{gsub(/,/,"",$1); print $1}')
  docker rm -f cs-probe cs-driver >/dev/null 2>&1
  echo "${cs:-DEAD}"
}

m=$(measure "$MUSL")
g=$(measure "$GLIBC")

if [ "$m" = "DEAD" ] || [ "$g" = "DEAD" ] || [ -z "$m" ] || [ -z "$g" ]; then
  echo "INCONCLUSIVE  musl=$m glibc=$g  workload=[$WORK]"
  exit 2
fi

ratio=$(awk -v a="$m" -v b="$g" 'BEGIN{ if (b+0==0) print 999; else printf "%.2f", a/b }')
verdict=$(awk -v r="$ratio" -v t="$THRESH" 'BEGIN{ print (r+0 >= t+0) ? "RED" : "GREEN" }')
printf '%-6s ratio=%-7s musl=%-9s glibc=%-9s  workload=[%s]\n' "$verdict" "$ratio" "$m" "$g" "$WORK"
