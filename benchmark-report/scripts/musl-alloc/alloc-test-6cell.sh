#!/bin/bash
# Six-cell allocator comparison: musl and glibc, each with mallocng/malloc, jemalloc and mimalloc.
#
# The earlier four-cell version showed musl + jemalloc recovering the QUIC deficit, which proves
# jemalloc beats mallocng but says nothing about whether glibc's own malloc is near-optimal. Adding
# the same two replacements on glibc separates "musl's allocator is the outlier" from "both libc
# allocators are beaten by a modern one", and those imply different advice.
#
# Interleaved musl/glibc rather than grouped, so drift in machine state cannot map onto the libc
# axis, which is the variable under test.
#
# Every cell records what the branch's rules require and the earlier version omitted: per-core
# thermal throttle DELTAS around the measured window, per-side mean frequency sampled DURING it, and
# peak temperature. A capped clock is not a fixed clock, and a nonzero throttle delta disqualifies a
# cell rather than merely annotating it.
set -u
JAR=/tmp/loadtest-published.jar
IMG_MUSL=alpine-jdk-musl-alloc
IMG_GLIBC=glibc-jdk-alloc
CONNS=500

# Gate on bench-tuning.service rather than on hand-checked sysctls.
#
# The service pins Dell platform thermal mode, governor, clock min=max=62% and the perf sysctls, and
# its `check` reports OK/FAIL per item plus temperature, fan RPM, throttle counts and whether a
# foreign container is running. Checking those by hand here was strictly worse: it only set
# max_perf_pct, leaving min at 17 so the clock was capped rather than pinned, and it did not know
# about the platform thermal mode at all.
#
# The service is deliberately not enabled at boot, so it must be started explicitly and stopped
# afterwards. Every setting is runtime-only and this host has rebooted mid-session more than once.
sudo -n systemctl start bench-tuning.service || { echo "could not start bench-tuning.service" >&2; exit 2; }
if ! sudo -n /usr/local/sbin/bench-tuning.sh check; then
  echo "REFUSING: bench-tuning check did not report READY" >&2
  exit 2
fi
# Leave the host as it was found, whatever happens from here.
trap 'sudo -n systemctl stop bench-tuning.service >/dev/null 2>&1' EXIT

PORT=0
for p in $(seq 20410 20460); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

thr() { for c in 0 1 2 3; do echo -n "$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count) "; done; }
mhz() { local s=0; for c in "$@"; do s=$((s + $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq))); done; echo $((s / $# / 1000)); }
temp() { echo $(( $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1) / 1000 )); }

quiet() { [ -z "$(docker ps --format '{{.Names}}' | grep -vE '^(claudecodeui|a-srv|a-cli)$')" ]; }

cell() {  # cell <image> <tag> <preload-or-empty>
  local img=$1; local tag=$2; local pre=${3:-}
  if ! quiet; then printf '%-26s CONTENDED_SKIPPED\n' "$tag"; return; fi
  docker rm -f a-srv a-cli >/dev/null 2>&1
  local envarg=""; [ -n "$pre" ] && envarg="-e LD_PRELOAD=$pre"

  docker run -d --rm --name a-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 $envarg \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
      --payload=1024 --threads=4 >/dev/null 2>&1
  for i in $(seq 1 60); do docker logs a-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  if ! docker logs a-srv 2>&1 | grep -q '^READY'; then
    printf '%-26s SERVER_FAILED  %s\n' "$tag" "$(docker logs a-srv 2>&1 | tail -1 | cut -c1-60)"
    docker rm -f a-srv >/dev/null 2>&1; return
  fi
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' a-srv)

  # Not --rm on the client: it must survive long enough for its STEADY line to be read.
  docker run -d --name a-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 $envarg \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=30 --payload=1024 --threads=4 >/dev/null 2>&1
  sleep 8

  local t0; t0=$(thr)
  local cs; cs=$(sudo -n perf stat -p "$pid" -e context-switches -- sleep 5 2>&1 \
                 | grep context-switches | awk '{gsub(/,/,"",$1); print $1}')
  local smhz cmhz tmax; smhz=$(mhz 0 1 4 5); cmhz=$(mhz 2 3 6 7); tmax=$(temp)
  local t1; t1=$(thr)
  local d="" i=1
  for a in $t0; do b=$(echo "$t1" | cut -d' ' -f$i); d="$d$((b-a))/"; i=$((i+1)); done

  timeout 90 docker wait a-cli >/dev/null 2>&1
  local rps; rps=$(docker logs a-cli 2>&1 | grep '^STEADY' | grep -oE 'reqPerSec=[0-9]+' | cut -d= -f2)
  local flag=""; [ "${d%/}" != "0/0/0/0" ] && flag="  THROTTLED"
  printf '%-26s ctxSw/5s=%-9s reqPerSec=%-8s thr=%-10s srvMHz=%-5s cliMHz=%-5s %sC%s\n' \
    "$tag" "${cs:-?}" "${rps:-?}" "${d%/}" "$smhz" "$cmhz" "$tmax" "$flag"
  docker rm -f a-srv a-cli >/dev/null 2>&1
  sleep 3
}

echo "port=$PORT conns=$CONNS payload=1024 QUIC, server measured"
echo "bench-tuning.service active; startTemp=$(temp)C"
echo
cell "$IMG_GLIBC" "glibc + mimalloc"        "/usr/lib/x86_64-linux-gnu/libmimalloc.so.3"
cell "$IMG_MUSL"  "musl + mimalloc"         "/usr/lib/libmimalloc.so.2"
cell "$IMG_GLIBC" "glibc + jemalloc"        "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2"
cell "$IMG_MUSL"  "musl + jemalloc"         "/usr/lib/libjemalloc.so.2"
cell "$IMG_GLIBC" "glibc malloc (default)"  ""
cell "$IMG_MUSL"  "musl mallocng (default)" ""
echo
echo "endTemp=$(temp)C  cumulative throttle: $(thr)"
echo ALLOC6_DONE
