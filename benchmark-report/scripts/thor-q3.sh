#!/bin/bash
# Q3: why is epoll ~39% faster than io_uring on plaintext, and the ordering reversed with TLS?
#
# The hypothesis: TLS multiplies syscalls per request (record framing means SslHandler issues
# several smaller reads and writes per application message). epoll pays a syscall each time;
# io_uring batches them into one submission. That predicts io_uring losing where syscalls are few
# and cheap, and winning where they are many.
#
# stime per request tests it directly. Interleaved, because grouping would map drift onto the very
# axis under test.
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

one() {
  local t=$1
  local tls=$2
  local name="q3-$t-$tls"
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
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 \
    > /tmp/q3c.out 2>&1

  local rps ucli scli gc
  rps=$(grep '^STEADY' /tmp/q3c.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  ucli=$(grep '^CLIENTCPU' /tmp/q3c.out | sed -E 's/.*utimeUsPerReq=([0-9.]+).*/\1/')
  scli=$(grep '^CLIENTCPU' /tmp/q3c.out | sed -E 's/.*stimeUsPerReq=([0-9.]+).*/\1/')
  gc=$(grep '^CLIENTCPU' /tmp/q3c.out | sed -E 's/.*gcMs=([0-9]+).*/\1/')

  # Server side: bracket the steady window with the last two SERVERCPU lines and divide the CPU
  # delta by the request delta, so the ramp's ten thousand handshakes stay out of the number.
  local srv
  srv=$(docker logs "$name" 2>&1 | grep '^SERVERCPU' | tail -6 | awk '
    NR==1 {r0=$3; u0=$4; s0=$5}
    END   {r1=$3; u1=$4; s1=$5;
           gsub(/[a-zA-Z=]/,"",r0); gsub(/[a-zA-Z=]/,"",r1);
           gsub(/[a-zA-Z=]/,"",u0); gsub(/[a-zA-Z=]/,"",u1);
           gsub(/[a-zA-Z=]/,"",s0); gsub(/[a-zA-Z=]/,"",s1);
           dr=r1-r0; if (dr>0) printf "%.2f %.2f", (u1-u0)*1000/dr, (s1-s0)*1000/dr; else printf "- -"}')
  printf '%-9s %-6s %-9s %-7s %-7s %-6s %s\n' "$t" "$tls" "${rps:--}" "${ucli:--}" "${scli:--}" "${gc:--}" "$srv"
  docker rm -f "$name" >/dev/null 2>&1
}

echo "transport tls    reqPerSec cliU/req cliS/req gcMs  srvU/req srvS/req"
for r in $(seq 1 $ROUNDS); do
  one epoll    none
  one io_uring none
  one epoll    openssl
  one io_uring openssl
  echo "-- round $r done"
done
echo Q3_DONE
