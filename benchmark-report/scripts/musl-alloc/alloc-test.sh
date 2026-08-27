#!/bin/bash
# Prediction under test: if quiche's native allocation through musl's mallocng drives the 12x
# context-switch excess on QUIC, replacing the allocator via LD_PRELOAD collapses it.
#
# mallocng serialises on a shared lock -- __lock and __unlock are the observed futex callers, and
# __libc_malloc_impl, alloc_slot and get_meta are the top musl CPU frames. jemalloc and mimalloc
# both use per-thread caches, so under this hypothesis both should behave like glibc.
#
# Two allocators are tried rather than one, so a result cannot be a quirk of a single replacement.
# Throughput is reported alongside the switch count because collapsing the switches without
# recovering throughput would mean the switches were a symptom rather than the cost.
#
# The falsification is explicit: if switches stay near 32k with both allocators, quiche's allocation
# is NOT the mechanism and the earlier "allocation is ruled out" conclusion stands after all, just
# for a different reason than I first gave.
set -u
JAR=/tmp/loadtest-published.jar
IMG_MUSL=alpine-jdk-musl-alloc
IMG_GLIBC=eclipse-temurin:21-jdk
CONNS=500

PORT=0
for p in $(seq 20110 20160); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {  # cell <image> <tag> <preload-or-empty>
  local img=$1; local tag=$2; local pre=${3:-}
  docker rm -f a-srv a-cli >/dev/null 2>&1
  local envarg=""
  [ -n "$pre" ] && envarg="-e LD_PRELOAD=$pre"

  docker run -d --rm --name a-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 $envarg \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
      --payload=1024 --threads=4 >/dev/null 2>&1
  for i in $(seq 1 60); do docker logs a-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  if ! docker logs a-srv 2>&1 | grep -q '^READY'; then
    printf '%-26s SERVER_FAILED  %s\n' "$tag" "$(docker logs a-srv 2>&1 | tail -1 | cut -c1-70)"
    docker rm -f a-srv >/dev/null 2>&1; return
  fi
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' a-srv)

  docker run -d --name a-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 $envarg \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=30 --payload=1024 --threads=4 >/dev/null 2>&1
  sleep 8

  local cs
  cs=$(sudo -n perf stat -p "$pid" -e context-switches -- sleep 5 2>&1 \
       | grep context-switches | awk '{gsub(/,/,"",$1); print $1}')
  # Let the client finish so its STEADY line gives throughput for the same configuration.
  local rps
  timeout 90 docker wait a-cli >/dev/null 2>&1
  rps=$(docker logs a-cli 2>&1 | grep '^STEADY' | grep -oE 'reqPerSec=[0-9]+' | cut -d= -f2)
  printf '%-26s ctxSwitches/5s=%-10s reqPerSec=%s\n' "$tag" "${cs:-?}" "${rps:-?}"
  docker rm -f a-srv a-cli >/dev/null 2>&1
  sleep 2
}

echo "port=$PORT conns=$CONNS payload=1024  QUIC, server measured"
cell "$IMG_MUSL"  "musl mallocng (default)"  ""
cell "$IMG_MUSL"  "musl + jemalloc"          "/usr/lib/libjemalloc.so.2"
cell "$IMG_MUSL"  "musl + mimalloc"          "/usr/lib/libmimalloc.so.2"
cell "$IMG_GLIBC" "glibc (control)"          ""
echo ALLOCTEST_DONE
