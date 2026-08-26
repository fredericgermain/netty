#!/bin/bash
# Cross the transports: which SIDE owns the deficit?
#
# Every run so far used the same transport on both ends, so "io_uring is 30% slower" is really
# "io_uring on both ends is 30% slower" and cannot separate the two. The CPU counters already
# pointed at the client (io_uring saved 17% of kernel time on the server while costing 61% more
# user time on the client), but that was an inference from per-request CPU, not a direct
# measurement of throughput with one side held fixed.
#
# Client and server are separate processes that only share a TCP connection, so the transport on
# each end is independent and the full 2x2 is free. Holding the client at epoll and varying only
# the server isolates the server contribution; holding the server at epoll and varying only the
# client isolates the client's.
#
# Interleaved, five rounds, for the usual reason: grouping maps machine drift onto the axis
# under test.
set -u
JAR=/home/fred/tls-matrix/loadtest-br.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=10
ROUNDS=5

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

one() {  # one <server-transport> <client-transport>
  local st=$1
  local ct=$2
  local name="x-$st-$ct"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$st" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "SERVERFAIL"; docker rm -f "$name" >/dev/null 2>&1; return; }

  timeout 120 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$ct" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 \
    > /tmp/x.out 2>&1

  local rps u s
  rps=$(grep '^STEADY' /tmp/x.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  u=$(grep '^CLIENTCPU' /tmp/x.out | sed -E 's/.*utimeUsPerReq=([0-9.]+).*/\1/')
  s=$(grep '^CLIENTCPU' /tmp/x.out | sed -E 's/.*stimeUsPerReq=([0-9.]+).*/\1/')

  # Server CPU across the steady window only, so the ramp's ten thousand accepts stay out of it.
  local srv
  srv=$(docker logs "$name" 2>&1 | grep '^SERVERCPU' | tail -6 | awk '
    NR==1 {r0=$3; u0=$4; s0=$5}
    END   {r1=$3; u1=$4; s1=$5;
           gsub(/[a-zA-Z=]/,"",r0); gsub(/[a-zA-Z=]/,"",r1);
           gsub(/[a-zA-Z=]/,"",u0); gsub(/[a-zA-Z=]/,"",u1);
           gsub(/[a-zA-Z=]/,"",s0); gsub(/[a-zA-Z=]/,"",s1);
           dr=r1-r0; if (dr>0) printf "%.2f %.2f", (u1-u0)*1000/dr, (s1-s0)*1000/dr; else printf "- -"}')

  printf '%-10s' "${rps:--}"
  echo "srv=$st cli=$ct rps=${rps:--} cliU=${u:--} cliS=${s:--} srvU/S=$srv" >> /tmp/x-detail.log
  docker rm -f "$name" >/dev/null 2>&1
}

: > /tmp/x-detail.log
echo "         srv=epoll  srv=uring  srv=epoll  srv=uring"
echo "round    cli=epoll  cli=epoll  cli=uring  cli=uring"
for r in $(seq 1 $ROUNDS); do
  printf '%-8s ' "$r"
  one epoll    epoll
  one io_uring epoll
  one epoll    io_uring
  one io_uring io_uring
  echo
done
echo "--- per-cell detail:"
cat /tmp/x-detail.log
echo CROSS_DONE
