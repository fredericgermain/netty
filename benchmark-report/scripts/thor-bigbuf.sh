#!/bin/bash
# Buffer rings where they should actually matter: large payloads.
#
# The 1 KB sweep found buffer rings made no difference, and that was taken as the answer. The
# payload sweep says the question was asked at the wrong size: io_uring's deficit WIDENS with
# message size, from 13% at 1 KB to 53% at 64 KB, which is the opposite of what amortising a fixed
# per-operation overhead would do.
#
# The kernel profile says what the extra time is, and it is not I/O. io_uring carries a class of
# frames epoll does not have at all: do_user_addr_fault 2.31%, refill_stock 1.78%, clear_page_erms
# 1.48%, page_counter_try_charge 1.26%. Page faulting, page zeroing and cgroup memory accounting,
# about 6.8% of its kernel time, none of it in epoll's top frames.
#
# That is the signature of allocating fresh pages during steady state, and without a provided buffer
# ring netty allocates a receive ByteBuf per read sized by the adaptive allocator. At 1 KB that is
# cheap enough to hide. At 64 KB it is a 64 KB direct buffer per read. A buffer ring pre-allocates
# and recycles instead, so if this mechanism is right, the knob that did nothing at 1 KB should
# matter here.
#
# If it does not, the memory-churn story is wrong and the profile is pointing somewhere else.
set -u
JAR=/home/fred/tls-matrix/loadtest-zc.jar
IMG=eclipse-temurin:21-jdk-alpine
DUR=10
PAY=65536
CONNS=2000
ROUNDS=3

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

one() {  # one <transport> <buffer-ring entries> <buffer size>
  local t=$1
  local br=$2
  local bs=$3
  local name="bb-$t-$br-$bs"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 --buffer-ring="$br" --buffer-ring-size="$bs" >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || {
    printf '%-12s' SRVFAIL
    docker logs "$name" 2>&1 | grep -i exception | head -1 >> /tmp/bb-err.log
    docker rm -f "$name" >/dev/null 2>&1; return; }

  timeout 150 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 \
      --buffer-ring="$br" --buffer-ring-size="$bs" > /tmp/bb.out 2>&1

  local rps u s
  rps=$(grep '^STEADY' /tmp/bb.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  u=$(grep '^CLIENTCPU' /tmp/bb.out | sed -E 's/.*utimeUsPerReq=([0-9.]+).*/\1/')
  s=$(grep '^CLIENTCPU' /tmp/bb.out | sed -E 's/.*stimeUsPerReq=([0-9.]+).*/\1/')
  if [ -z "${rps:-}" ]; then
    printf '%-12s' CLIFAIL
    grep -iE 'exception|error' /tmp/bb.out | head -1 >> /tmp/bb-err.log
  else
    printf '%-12s' "$rps"
    echo "$t br=$br bs=$bs rps=$rps MBps=$(( rps * PAY / 1048576 )) cliU=$u cliS=$s" >> /tmp/bb-detail.log
  fi
  docker rm -f "$name" >/dev/null 2>&1
}

: > /tmp/bb-detail.log; : > /tmp/bb-err.log
echo "payload=$PAY connections=$CONNS"
echo "round  epoll       uring-br0   uring-br512 uring-br2048"
echo "                               (64k bufs)  (16k bufs)"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one epoll    0 2048
  one io_uring 0 2048
  one io_uring 512 65536
  one io_uring 2048 16384
  echo
done
echo "--- detail:"
cat /tmp/bb-detail.log
echo "--- errors:"
cat /tmp/bb-err.log
echo BIGBUF_DONE
