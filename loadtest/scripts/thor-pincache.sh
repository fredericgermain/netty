#!/bin/bash
# Task 0: quantify the SMT pinning artifact, and the cheapest remediation candidate, in one
# interleaved sweep so every cell sees the same machine drift.
#
# Pinning: thor's cpu0-3 and cpu4-7 are not disjoint cores. thread_siblings_list says 0,4 / 1,5 /
# 2,6 / 3,7, so the old pinning (server 0-3, client 4-7) ran client and server as hyperthread
# siblings on the SAME four physical cores. New pinning gives each side two whole physical cores
# with both their threads: server 0,1,4,5 and client 2,3,6,7. Both pinnings are measured here so
# the artifact's size is a number rather than an assumption.
#
# Cache ceiling: PooledByteBufAllocator's thread-local cache refuses buffers above
# io.netty.allocator.maxCachedBufferCapacity, default 32 KB. Above it every receive buffer goes to
# the arena, and a completion-based transport holds one per read in flight. The cliff sits right at
# that boundary (75% of epoll at 8 KB, 47% at 64 KB), so raising the ceiling to 256 KB on both
# transports is the one-flag test: if io_uring closes most of the gap and epoll barely moves, the
# footprint mechanism is confirmed and the fix is a JVM flag.
set -u
JAR=/home/fred/tls-matrix/loadtest-pin.jar
IMG=eclipse-temurin:21-jdk-alpine
DUR=10
PAY=${1:?payload bytes}
CONNS=${2:?connections}
ROUNDS=${3:-5}
TAG=${4:-pc}
CACHEFLAG=-Dio.netty.allocator.maxCachedBufferCapacity=262144

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT payload=$PAY connections=$CONNS rounds=$ROUNDS"

DETAIL=/tmp/$TAG-detail.log
ERRS=/tmp/$TAG-err.log
: > "$DETAIL"; : > "$ERRS"

one() {  # one <label> <transport> <server cpus> <client cpus> <extra jvm flags or ->
  local label=$1 t=$2 scpus=$3 ccpus=$4 jflags=$5
  [ "$jflags" = "-" ] && jflags=""
  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus="$scpus" \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jflags -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    printf '%-11s' SRVFAIL
    docker logs "$name" 2>&1 | tail -3 >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi

  timeout 150 docker run --rm --network=host --cpuset-cpus="$ccpus" \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jflags -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 > /tmp/$TAG.out 2>&1

  local rps mem
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  # min-max of the server's pooled direct memory across the run, the churn signature.
  mem=$(docker logs "$name" 2>&1 | grep -o 'usedDirectMb=[0-9]*' | cut -d= -f2 \
        | sort -n | awk 'NR==1{min=$1} {max=$1} END{if (NR) printf "%d-%dMB", min, max}')
  if [ -z "${rps:-}" ]; then
    printf '%-11s' CLIFAIL
    grep -iE 'exception|error' /tmp/$TAG.out | head -2 >> "$ERRS"
  else
    printf '%-11s' "$rps"
    echo "$label rps=$rps srvPool=$mem $(grep '^CLIENTCPU' /tmp/$TAG.out)" >> "$DETAIL"
  fi
  docker rm -f "$name" >/dev/null 2>&1
}

echo "round  ep-old     ur-old     ep-new     ur-new     ep-new-c   ur-new-c"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one ep-old     epoll    0-3     4-7     -
  one ur-old     io_uring 0-3     4-7     -
  one ep-new     epoll    0,1,4,5 2,3,6,7 -
  one ur-new     io_uring 0,1,4,5 2,3,6,7 -
  one ep-new-c   epoll    0,1,4,5 2,3,6,7 "$CACHEFLAG"
  one ur-new-c   io_uring 0,1,4,5 2,3,6,7 "$CACHEFLAG"
  echo
done
echo "--- detail:"
cat "$DETAIL"
echo "--- errors:"
cat "$ERRS"
echo PINCACHE_DONE
