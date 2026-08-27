#!/bin/bash
# What is actually parking on musl, given it is not the allocator?
#
# Refuted: allocation lock contention. --prealloc cut musl's page faults by 31% and left its context
# switches at 34k, unchanged. So the 12.9x context-switch gap over glibc survives a large reduction
# in allocation and has a different cause.
#
# Leading hypothesis now: musl's pthread primitives park almost immediately where glibc's spin
# adaptively first. Under that hypothesis the callers matter more than the count, because any
# contended lock on musl converts straight into a futex syscall and a deschedule, while the same
# contention on glibc is absorbed in userspace.
#
# Tracing the futex entry tracepoint with call graphs names the callers directly, which is the one
# thing the sampled profile could not do: a thread that is parked is not on-CPU, so a CPU profiler
# cannot see the wait at all. thread count is also swept, since contention should scale with it and
# a per-thread cost should not.
set -u
JAR=/tmp/loadtest-published.jar
OUT=/tmp/quicfutex
CONNS=500

rm -rf "$OUT"; mkdir -p "$OUT"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

run() {  # run <image> <tag> <threads>
  local img=$1; local tag=$2; local th=$3
  docker rm -f q-srv q-cli >/dev/null 2>&1

  docker run -d --rm --name q-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
      --payload=1024 --threads=$th >/dev/null
  for i in $(seq 1 60); do docker logs q-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs q-srv 2>&1 | grep -q '^READY' || { echo "$tag SERVER_FAILED"; docker rm -f q-srv >/dev/null 2>&1; return; }
  local pid; pid=$(pgrep -f "lt.jar server --protocol=quic.*--port=$PORT" | head -1)

  docker run -d --rm --name q-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=22 --payload=1024 --threads=4 >/dev/null
  sleep 6

  local cs
  cs=$(sudo -n perf stat -p "$pid" -e context-switches -- sleep 5 2>&1 | grep context-switches | awk '{print $1}')
  printf '%-22s threads=%-3s ctxSwitches/5s=%s\n' "$tag" "$th" "$cs"

  if [ "$th" = "4" ]; then
    # Count futex entries and name their callers. Sampled at 1 in 97 to keep the trace small; the
    # ratio between callers is what matters, not the absolute count.
    sudo -n perf record -q -e syscalls:sys_enter_futex -c 97 -g -p "$pid" -o "$OUT/$tag.data" -- sleep 5 >/dev/null 2>&1
    echo "    futex callers:"
    sudo -n perf report -i "$OUT/$tag.data" --no-children --sort=symbol --percent-limit=4 2>/dev/null \
      | grep -vE "^#|^$|^\s*$" | head -8 | sed 's/^/      /'
  fi

  docker rm -f q-srv q-cli >/dev/null 2>&1
  sleep 2
}

echo "port=$PORT conns=$CONNS  -- server side"
run alpine-jdk-musldbg     musl  4
run eclipse-temurin:21-jdk glibc 4
echo "--- thread sweep: contention should scale with threads, a per-thread cost should not"
run alpine-jdk-musldbg     musl  1
run eclipse-temurin:21-jdk glibc 1
echo QUICFUTEX_DONE
