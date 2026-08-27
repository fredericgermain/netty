#!/bin/bash
# musl vs glibc for netty QUIC, instrumented, and with the allocator as a tested variable.
#
# The first run of this comparison put musl about 17% behind glibc with non-overlapping ranges, and
# that figure is now quoted in an upstream PR. It was taken WITHOUT recording per-cell frequency or
# throttle deltas, which this branch's own rules require, so it is not yet safe.
#
# Two things are added here.
#
# 1. Instrumentation. Clock is capped at max_perf_pct=62 for stability, but "capped" is not "fixed":
#    under the performance governor this host still ranges widely, and it thermally throttles under
#    sustained load. Both sides are sampled separately because server and client sit on different
#    physical cores, so a one-sided clock difference would masquerade as a libc difference.
#
# 2. The allocator as a hypothesis, not an assumption. musl's mallocng and glibc's malloc differ
#    substantially, and the QUIC path allocates roughly 875 B/req against the pre-allocated TCP
#    path's 5-23. If the gap is the allocator, --prealloc should shrink it. If the gap survives
#    --prealloc, the allocator is not the explanation and the PR should say so rather than leave a
#    plausible-sounding cause unstated.
set -u
JAR=/tmp/loadtest-published.jar
CONNS=500
DUR=10
ROUNDS=5

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

thr() { for c in 0 1 2 3; do echo -n "$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null) "; done; }
mhz() { for c in "$@"; do echo -n "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) "; done; }

# A contended cell on this host has been observed to invert an ordering outright rather than merely
# widen a spread, so foreign load disqualifies a cell instead of annotating it.
quiet() {
  local f
  f=$(docker ps --format '{{.Names}}' | grep -vE '^(claudecodeui|q-srv|q-cli)$' || true)
  [ -z "$f" ]
}

cell() {  # cell <image> <label> <extra args>
  local img=$1; local label=$2; shift 2
  local extra="$*"
  if ! quiet; then echo "$label CONTENDED_SKIPPED"; return; fi
  docker rm -f q-srv q-cli >/dev/null 2>&1

  local t0; t0=$(thr)
  docker run -d --rm --name q-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
         --payload=1024 --threads=4 $extra >/dev/null
  for i in $(seq 1 60); do docker logs q-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  if ! docker logs q-srv 2>&1 | grep -q '^READY'; then
    echo "$label SERVER_FAILED  $(docker logs q-srv 2>&1 | grep -iE 'exception|error' | head -1)"
    docker rm -f q-srv >/dev/null 2>&1; return
  fi

  docker run -d --name q-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 $extra >/dev/null

  # Sample mid-window rather than at the boundaries: the clock that matters is the one during the
  # measurement, not the one while the ramp is still opening streams.
  sleep 8
  local smhz cmhz
  smhz=$(mhz 0 1 4 5); cmhz=$(mhz 2 3 6 7)

  timeout 150 docker wait q-cli >/dev/null 2>&1
  local out; out=$(docker logs q-cli 2>&1)
  local t1; t1=$(thr)
  local d=""; local i=1
  for a in $t0; do
    b=$(echo "$t1" | cut -d' ' -f$i); d="$d$((b-a))/"; i=$((i+1))
  done

  local rps err alloc
  rps=$(echo "$out" | grep '^STEADY' | grep -oE 'reqPerSec=[0-9]+' | cut -d= -f2)
  err=$(echo "$out" | grep '^STEADY' | grep -oE 'errors=[0-9]+' | cut -d= -f2)
  alloc=$(echo "$out" | grep '^STEADY' | grep -oE 'allocBytesPerReq=[0-9.]+' | cut -d= -f2)
  printf '%-22s rps=%-8s err=%-4s allocB/req=%-8s thrDelta=%-12s srvMHz=%s cliMHz=%s\n' \
    "$label" "${rps:-FAIL}" "${err:--}" "${alloc:--}" "${d%/}" \
    "$(echo $smhz | awk '{printf "%d", ($1+$2+$3+$4)/4000}')" \
    "$(echo $cmhz | awk '{printf "%d", ($1+$2+$3+$4)/4000}')"
  docker rm -f q-srv q-cli >/dev/null 2>&1
}

echo "port=$PORT conns=$CONNS dur=${DUR}s rounds=$ROUNDS payload=1024"
echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) max_perf_pct=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
echo "jar built against published 4.2.18.Final-20260827.083944-1"
echo
for r in $(seq 1 $ROUNDS); do
  cell eclipse-temurin:21-jdk-alpine "r$r musl  default"
  cell eclipse-temurin:21-jdk       "r$r glibc default"
  cell eclipse-temurin:21-jdk-alpine "r$r musl  prealloc" --prealloc
  cell eclipse-temurin:21-jdk       "r$r glibc prealloc" --prealloc
done
docker rm -f q-srv q-cli >/dev/null 2>&1
echo MUSLQUIC2_DONE
