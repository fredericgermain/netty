#!/bin/bash
# At what message size does io_uring stop losing, and can zero-copy send make it win?
#
# Everything so far used a 1 KB payload, chosen deliberately to keep the test syscall-bound. That is
# the worst case for io_uring: the syscall it replaces is a cheap loopback copy, so the ring's
# per-operation bookkeeping is pure overhead with nothing to amortise it against.
#
# Two predictions, and they are different claims:
#
#   1. Raising the payload should shrink the gap in RELATIVE terms, because a fixed per-operation
#      overhead matters less against more work per operation. This should happen for both
#      transports and does not make io_uring win, it makes the difference stop mattering.
#
#   2. IORING_OP_SEND_ZC is the only lever that could make io_uring win OUTRIGHT, because netty's
#      epoll transport has no equivalent -- it does not use MSG_ZEROCOPY. Zero-copy send removes the
#      copy entirely at the cost of pinning pages and taking a second completion, so it should lose
#      at small sizes and win somewhere above the crossover.
#
# Connections are scaled down as the payload grows: 10k connections at 256 KB would be 2.5 GB in
# flight per direction and the test would measure memory, not the transport.
set -u
JAR=/home/fred/tls-matrix/loadtest-zc.jar
IMG=eclipse-temurin:21-jdk-alpine
DUR=10

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

one() {  # one <transport> <payload> <connections> <zc-threshold, -1 = off>
  local t=$1
  local pay=$2
  local conns=$3
  local zc=$4
  local name="p-$t-$pay-$zc"
  local zcarg=""
  [ "$zc" -ge 0 ] && zcarg="--zc-threshold=$zc"

  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 $zcarg >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || {
    printf '%-12s' "SRVFAIL"; docker logs "$name" 2>&1 | grep -i 'exception' | head -1 >> /tmp/p-err.log
    docker rm -f "$name" >/dev/null 2>&1; return; }

  timeout 150 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$conns --duration=$DUR --payload=$pay --threads=4 $zcarg \
    > /tmp/p.out 2>&1

  local rps
  rps=$(grep '^STEADY' /tmp/p.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  if [ -z "${rps:-}" ]; then
    printf '%-12s' "CLIFAIL"
    grep -iE 'exception|error' /tmp/p.out | head -1 >> /tmp/p-err.log
  else
    # MB/s both ways is the comparable figure once payload varies; req/s alone is not.
    printf '%-12s' "$rps"
    echo "$t pay=$pay conns=$conns zc=$zc rps=$rps MBps=$(( rps * pay / 1048576 ))" >> /tmp/p-detail.log
  fi
  docker rm -f "$name" >/dev/null 2>&1
}

: > /tmp/p-detail.log; : > /tmp/p-err.log
echo "payload  conns   epoll       uring       uring+zc"
# Connection count falls as payload rises so total bytes in flight stays sane.
run_row() {
  local pay=$1
  local conns=$2
  local zcth=$3
  printf '%-8s %-7s ' "$pay" "$conns"
  one epoll    "$pay" "$conns" -1
  one io_uring "$pay" "$conns" -1
  one io_uring "$pay" "$conns" "$zcth"
  echo
}

# zc threshold set just below the payload so zero-copy actually engages for that row.
run_row 1024   10000 512
run_row 8192   10000 4096
run_row 65536  2000  32768
run_row 262144 500   131072

echo "--- detail:"
cat /tmp/p-detail.log
echo "--- errors seen:"
cat /tmp/p-err.log
echo PAYLOAD_DONE
