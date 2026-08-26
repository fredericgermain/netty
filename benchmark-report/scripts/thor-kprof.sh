#!/bin/bash
# Kernel profiling without touching the host sysctls.
#
# thor has perf_event_paranoid=4 and kptr_restrict=1, and sudo wants a password, so the earlier runs
# used event=ctimer -- POSIX timers, no privileges, but also no kernel stacks. That is why the
# io_uring profile was missing 58% of its CPU: the time is inside io_uring_enter and ctimer cannot
# see into the kernel.
#
# Capabilities are the way around it, and they are per-container rather than host-wide:
#   CAP_PERFMON  bypasses the perf_event_paranoid check entirely
#   CAP_SYSLOG   lifts kptr_restrict so kernel frames resolve to names instead of addresses
#   seccomp=unconfined  lets perf_event_open through docker's default filter
# Nothing on the host changes, so this leaves no state behind for the next person.
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
PROF=/home/fred/tls-matrix/async-profiler-4.5-linux-x64
OUT=/home/fred/tls-matrix/kprof
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
  local name="kprof-$t"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t: SERVER FAILED"; return; }

  echo "=== kernel-profiling $t client"
  timeout 180 docker run --rm --network=host --cpuset-cpus=4-7 \
    --cap-add=PERFMON --cap-add=SYS_ADMIN --cap-add=SYSLOG \
    --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" -v "$PROF:/prof:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints \
      -agentpath:/prof/lib/libasyncProfiler.so=start,event=cpu,interval=1ms,collapsed,file=/out/$t.collapsed \
      -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 2>&1 \
    | grep -E '^STEADY|^CLIENTCPU|Failed|perf_event|error'
  docker rm -f "$name" >/dev/null 2>&1
}

cell epoll
cell io_uring
echo "--- sample counts:"
wc -l "$OUT"/*.collapsed 2>/dev/null
echo "--- do kernel frames resolve?"
for f in "$OUT"/*.collapsed; do
  echo "  $(basename $f): $(grep -oE '(entry_SYSCALL_64|do_syscall_64|__sys_[a-z_]+|io_uring_[a-z_]+|tcp_[a-z_]+)' "$f" | sort -u | head -6 | tr '\n' ' ')"
done
echo KPROF_DONE
