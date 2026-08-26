#!/bin/bash
# Does the io_uring server hold more pooled direct memory, and does a buffer ring fix it?
#
# The 256 KB profile showed the io_uring server allocating fresh arena chunks continuously
# (1201 samples in DirectArena.newChunk) against the epoll server's 7. Samples are not a rate, so
# this reports usedDirectMemory and the live chunk count directly, sampled every 2 s.
#
# The mechanism under test: a completion-based transport commits a receive buffer when it SUBMITS
# the read, not when data becomes available, so it holds one per read in flight rather than one per
# ready read. At 500 connections with a 256 KB adaptive receive buffer that is a different order of
# live memory. If that is right, the io_uring server's usedDirectMb should sit far above epoll's,
# and configuring a provided buffer ring -- where the kernel picks a buffer at completion time from
# a fixed pre-registered set -- should bring it back down.
set -u
JAR=/home/fred/tls-matrix/loadtest-pool.jar
IMG=eclipse-temurin:21-jdk-alpine
PAY=262144
CONNS=500
DUR=20

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {  # cell <transport> <buffer-ring entries> <buffer size>
  local t=$1
  local br=$2
  local bs=$3
  local name="pool-$t-$br"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 --buffer-ring="$br" --buffer-ring-size="$bs" >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t br=$br SERVERFAIL"; docker rm -f "$name" >/dev/null 2>&1; return; }

  local rps
  rps=$(timeout 150 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 \
      --buffer-ring="$br" --buffer-ring-size="$bs" 2>/dev/null \
    | grep '^STEADY' | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')

  printf '%-10s br=%-6s rps=%-8s pooled: ' "$t" "$br" "${rps:--}"
  # Every SERVERCPU line from the run, so growth is visible rather than just the final value.
  docker logs "$name" 2>&1 | grep '^SERVERCPU' | sed -E 's/.*usedDirectMb=([0-9]+) pooledChunks=([0-9]+).*/\1MB\/\2ch/' \
    | tr '\n' ' '
  echo
  docker rm -f "$name" >/dev/null 2>&1
}

echo "payload=$PAY connections=$CONNS -- usedDirectMb/pooledChunks sampled every 2s"
cell epoll    0 2048
cell io_uring 0 2048
cell io_uring 512 65536
echo POOL_DONE
