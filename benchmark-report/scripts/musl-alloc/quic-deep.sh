#!/bin/bash
# Open up the two opaque parts of musl's QUIC deficit: what inside libc, and why more kernel time.
#
# Established so far: musl costs 18% more CPU per request than glibc for the same netty QUIC work.
# By owner, libc is 46% of that gap, kernel 26%, quiche 19%, and netty's own Java 2%. The libc share
# is a single unresolved frame, /lib/ld-musl-x86_64.so.1, because musl links allocator, string and
# memory routines, pthread and the dynamic linker into one stripped image.
#
# Two instruments, because they answer different questions:
#
#   perf record  with musl-dbg installed, so the libc frame resolves into functions. Run from the
#                HOST against the container's PID, since perf and its symbol resolution work better
#                outside the container's mount namespace, and the host has the sysctls set.
#
#   perf stat    counts rather than samples. The kernel delta showed futex_wake and futex_hash
#                appearing ONLY on musl, and higher do_user_addr_fault, which are two concrete and
#                checkable hypotheses: musl's pthread doing more futex work, and its allocator
#                causing more page faults. Counting page-faults and context-switches tests both
#                directly, and a count is not subject to the sampling attribution problems that
#                have already misled once on this host.
set -u
JAR=/tmp/loadtest-published.jar
OUT=/tmp/quicdeep
CONNS=500
DUR=20

rm -rf "$OUT"; mkdir -p "$OUT"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {  # cell <image> <tag>
  local img=$1; local tag=$2
  docker rm -f q-srv >/dev/null 2>&1

  docker run -d --rm --name q-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints -XX:+PreserveFramePointer \
      -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
      --payload=1024 --threads=4 >/dev/null
  for i in $(seq 1 60); do docker logs q-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs q-srv 2>&1 | grep -q '^READY' || { echo "$tag SERVER_FAILED"; docker rm -f q-srv >/dev/null 2>&1; return; }

  local pid
  pid=$(pgrep -f "lt.jar server --protocol=quic.*--port=$PORT" | head -1)
  [ -z "$pid" ] && { echo "$tag NO_PID"; docker rm -f q-srv >/dev/null 2>&1; return; }

  # Client first, so the server is under load before either instrument attaches.
  timeout 150 docker run -d --rm --name q-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 >/dev/null
  sleep 6

  echo "=== $tag: perf stat over 8s of steady state"
  sudo -n perf stat -p "$pid" -e task-clock,context-switches,page-faults,minor-faults,cycles,instructions \
    -- sleep 8 2>&1 | grep -E "task-clock|context-switches|faults|cycles|instructions|seconds" | sed 's/^/    /'

  echo "=== $tag: perf record 8s, native leaves"
  sudo -n perf record -q -g -F 499 -p "$pid" -o "$OUT/$tag.data" -- sleep 8 >/dev/null 2>&1
  sudo -n perf report -i "$OUT/$tag.data" --no-children --sort=dso,symbol --percent-limit=0.8 2>/dev/null \
    | grep -vE "^#|^$" | head -14 | sed 's/^/    /'

  docker rm -f q-srv q-cli >/dev/null 2>&1
  sleep 2
}

echo "port=$PORT conns=$CONNS payload=1024  (server, perf from the host)"
cell alpine-jdk-musldbg      musl
cell eclipse-temurin:21-jdk  glibc
echo QUICDEEP_DONE
