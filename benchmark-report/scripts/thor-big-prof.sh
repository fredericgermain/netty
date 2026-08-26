#!/bin/bash
# Profile both transports at 256 KB, where io_uring is at its worst (41% of epoll).
#
# The 1 KB profile found a long tail and no hot spot, which is a bad basis for changing anything.
# The size sweep since then says the interesting regime is the other end: the deficit widens
# monotonically with payload, so whatever the mechanism is, it is 4x more visible at 256 KB than at
# 1 KB. If it has a signature, this is where it shows.
#
# Kernel frames included via capabilities, since the whole question is whether the extra cost is in
# the kernel (page faults, copies, memcg accounting) or in netty's Java completion path.
#
# Sample counts are printed against measured CPU deliberately. At 1 KB async-profiler accounted for
# epoll almost exactly and under-reported io_uring by 3.5x, so percentages from these files cannot
# be compared between transports until that ratio is checked again here.
set -u
JAR=/home/fred/tls-matrix/loadtest-zc.jar
PROF=/home/fred/tls-matrix/async-profiler-4.5-linux-x64
OUT=/home/fred/tls-matrix/bigprof
IMG=eclipse-temurin:21-jdk-alpine
PAY=262144
CONNS=500
DUR=20

rm -rf "$OUT"; mkdir -p "$OUT"; chmod 777 "$OUT"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {
  local t=$1
  local name="bp-$t"
  docker rm -f "$name" >/dev/null 2>&1
  # The SERVER is profiled too this time. At 1 KB only the client was, on the strength of a
  # client-side attribution that the transport-crossing run has since withdrawn.
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" -v "$PROF:/prof:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints \
      -agentpath:/prof/lib/libasyncProfiler.so=start,event=cpu,interval=1ms,collapsed,file=/out/$t-server.collapsed \
      -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t: SERVER FAILED"; return; }

  echo "=== $t"
  timeout 180 docker run --rm --network=host --cpuset-cpus=4-7 \
    --cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG \
    --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" -v "$PROF:/prof:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints \
      -agentpath:/prof/lib/libasyncProfiler.so=start,event=cpu,interval=1ms,collapsed,file=/out/$t-client.collapsed \
      -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 2>&1 \
    | grep -E '^STEADY|^CLIENTCPU'
  # Stop the server gently so the agent flushes its collapsed file.
  docker kill --signal=SIGTERM "$name" >/dev/null 2>&1
  for i in $(seq 1 20); do docker ps -q -f name="$name" | grep -q . || break; sleep 0.5; done
  docker rm -f "$name" >/dev/null 2>&1
  docker logs "$name" 2>&1 | grep '^SERVERCPU' | tail -1
}

cell epoll
cell io_uring
echo "--- sample counts (check against CLIENTCPU before quoting any percentage):"
wc -l "$OUT"/*.collapsed 2>/dev/null
echo BIGPROF_DONE
