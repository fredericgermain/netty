#!/bin/bash
# 10k connections on thor. Two questions, kept separate because one number cannot answer both:
#   closed loop -> maximum throughput (latency there is queue depth, not service time)
#   open loop   -> real latency at a rate the system can actually sustain
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=15

# Pick a free port rather than hardcoding one. A previous run's client hung in shutdown with a
# jammed io_uring completion queue, kept the port bound for four hours, and every subsequent cell
# reported SERVER FAILED with no indication why. The container it belonged to was gone, so docker
# could not clean it up and the process was root-owned. Choosing a port we have just confirmed free
# is cheaper than diagnosing that twice.
PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
if [ "$PORT" = 0 ]; then
  echo "no free port in 19990-20050; something is stuck. Check: ps -eo pid,args | grep lt.jar" >&2
  exit 2
fi
echo "using port $PORT"

cell() {  # cell <label> <transport> <tls> <extra-client-args> <ring>
  local label=$1 t=$2 tls=$3 extra=$4 ring=${5:-16384}
  local name="l3-$t-$tls"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls="$tls" --port=$PORT \
         --threads=4 --backlog=8192 --ring-size="$ring" >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  if ! docker logs "$name" 2>&1 | grep -q '^READY'; then
    printf '%-34s SERVER FAILED\n' "$label"; docker rm -f "$name" >/dev/null 2>&1; return
  fi
  printf '%-34s ' "$label"
  # Bound the client: the io_uring shutdown hang left a process alive for hours.
  timeout 180 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls="$tls" --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 --ring-size="$ring" $extra \
    > /tmp/c3.out 2>&1
  grep -E '^RAMP|^STEADY' /tmp/c3.out | tr '\n' ' '; echo
  grep -q '^STEADY' /tmp/c3.out || { echo "   client tail:"; tail -4 /tmp/c3.out | sed 's/^/     /'; }
  docker rm -f "$name" >/dev/null 2>&1
}

echo "=== A. io_uring ring size, plaintext, closed loop -- is the collapse the default ring?"
cell "io_uring ring=4096 (netty default)" io_uring none "" 4096
cell "io_uring ring=16384"                io_uring none "" 16384
cell "io_uring ring=32768"                io_uring none "" 32768

echo
echo "=== B. saturation throughput, closed loop (latency column is queue depth, ignore it)"
cell "nio      plaintext"  nio      none ""
cell "epoll    plaintext"  epoll    none ""
cell "io_uring plaintext"  io_uring none ""
cell "nio      boringssl"  nio      openssl ""
cell "epoll    boringssl"  epoll    openssl ""
cell "io_uring boringssl"  io_uring openssl ""

echo
echo "=== C. real latency, open loop at 100k req/s (well under saturation)"
cell "nio      plaintext @100k" nio      none    "--rate=100000"
cell "epoll    plaintext @100k" epoll    none    "--rate=100000"
cell "io_uring plaintext @100k" io_uring none    "--rate=100000"
cell "epoll    boringssl @50k"  epoll    openssl "--rate=50000"
cell "nio      boringssl @50k"  nio      openssl "--rate=50000"
echo LOAD3_DONE
