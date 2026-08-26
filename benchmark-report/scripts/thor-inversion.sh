#!/bin/bash
# Is the epoll/io_uring inversion real, or drift?
#
# The single-shot run showed epoll ahead on plaintext (166219 vs 125895) and io_uring ahead with
# TLS (104256 vs 95382). One sample each, on a box whose load average was near its core count.
#
# The fix is not "run it again" but "run it interleaved". Grouping all epoll cells then all io_uring
# cells maps any drift in machine state directly onto the transport axis, which is precisely the
# variable under test. Round-robin spreads drift across every cell instead, so a real ordering
# survives and a spurious one does not.
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=10
ROUNDS=5

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

one() {  # one <transport> <tls>
  # Separate statements: bash expands every word of a `local` before assigning any of them, so
  # referring to $t inside the same declaration hits "unbound variable" under set -u.
  local t=$1
  local tls=$2
  local name="inv-$t-$tls"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls="$tls" --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "SERVERFAIL"; docker rm -f "$name" >/dev/null 2>&1; return; }
  timeout 120 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls="$tls" --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 2>/dev/null \
    | grep '^STEADY' | sed -E 's/.*reqPerSec=([0-9]+).*/\1/'
  docker rm -f "$name" >/dev/null 2>&1
}

echo "round load1m  epoll-plain  iouring-plain  epoll-tls  iouring-tls"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s %-8s ' "$r" "$(cut -d' ' -f1 /proc/loadavg)"
  printf '%-13s' "$(one epoll none)"
  printf '%-15s' "$(one io_uring none)"
  printf '%-11s' "$(one epoll openssl)"
  printf '%s\n' "$(one io_uring openssl)"
done
echo INVERSION_DONE
