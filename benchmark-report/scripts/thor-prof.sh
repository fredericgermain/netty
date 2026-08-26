#!/bin/bash
# Profile the plaintext CLIENT under both transports and diff the two.
#
# The counters narrowed it: io_uring's plaintext deficit is client-side and mostly user CPU
# (13.53 us/req against epoll's 8.40), while the SERVER side actually saves kernel time with
# io_uring. So the server is not where to look -- the client is, and in user space, which is
# exactly what ctimer sees.
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
PROF=/home/fred/tls-matrix/async-profiler-4.5-linux-x64
OUT=/home/fred/tls-matrix/prof
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=20

rm -rf "$OUT"; mkdir -p "$OUT"; chmod 777 "$OUT"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {
  local t=$1
  local name="prof-$t"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t: SERVER FAILED"; return; }

  echo "=== profiling $t client"
  timeout 180 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" -v "$PROF:/prof:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints \
      -agentpath:/prof/lib/libasyncProfiler.so=start,event=ctimer,interval=1ms,collapsed,file=/out/$t.collapsed \
      -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 2>&1 \
    | grep -E '^STEADY|^CLIENTCPU'
  docker rm -f "$name" >/dev/null 2>&1
}

cell epoll
cell io_uring
echo "--- collapsed stacks:"
wc -l "$OUT"/*.collapsed 2>/dev/null
echo PROF_DONE
