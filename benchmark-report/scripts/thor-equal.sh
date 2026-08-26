#!/bin/bash
# Cause or effect? Hold the request rate equal and see whether the memory churn survives.
#
# The closed-loop run showed the io_uring server thrashing pooled arena chunks (8 to 36, peaking at
# 140 MB) while epoll sat flat at 32 MB / 8 chunks. That is suggestive but circular: io_uring is
# 2.3x slower, so at any instant more connections have a partially accumulated 256 KB frame, and
# more live memory follows from being slow rather than causing it.
#
# Open loop breaks the circle. Both transports are driven at the SAME fixed rate, comfortably below
# what either achieved (3966 and 9139 req/s closed loop), so throughput is no longer a free
# variable and the in-flight frame count is matched by construction.
#
#   If io_uring still churns at equal rate -> the allocation behaviour is a cause, and it is a
#   property of the transport rather than of its speed.
#   If the churn disappears -> it was an effect of being slower, and the real cause is elsewhere.
#
# CPU per request at equal rate is the second half of the answer, and is the cleanest comparison
# available anywhere in this branch: identical offered load, identical work, only the transport
# differs.
set -u
JAR=/home/fred/tls-matrix/loadtest-pool.jar
IMG=eclipse-temurin:21-jdk-alpine
PAY=262144
CONNS=500
DUR=20
RATE=2000

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {
  local t=$1
  local name="eq-$t"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t SERVERFAIL"; docker rm -f "$name" >/dev/null 2>&1; return; }

  echo "=== $t at --rate=$RATE"
  timeout 150 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 --rate=$RATE 2>/dev/null \
    | grep -E '^STEADY|^CLIENTCPU'
  echo -n "    server pooled: "
  docker logs "$name" 2>&1 | grep '^SERVERCPU' \
    | sed -E 's/.*usedDirectMb=([0-9]+) pooledChunks=([0-9]+).*/\1MB\/\2ch/' | tr '\n' ' '
  echo
  echo -n "    server cpu/req: "
  docker logs "$name" 2>&1 | grep '^SERVERCPU' | tail -6 | awk '
    NR==1 {r0=$3; u0=$4; s0=$5}
    END   {r1=$3; u1=$4; s1=$5;
           gsub(/[a-zA-Z=]/,"",r0); gsub(/[a-zA-Z=]/,"",r1);
           gsub(/[a-zA-Z=]/,"",u0); gsub(/[a-zA-Z=]/,"",u1);
           gsub(/[a-zA-Z=]/,"",s0); gsub(/[a-zA-Z=]/,"",s1);
           dr=r1-r0; if (dr>0) printf "utimeUs=%.1f stimeUs=%.1f over %d requests\n",
                                       (u1-u0)*1000/dr, (s1-s0)*1000/dr, dr; else print "-"}'
  docker rm -f "$name" >/dev/null 2>&1
}

cell epoll
cell io_uring
echo EQUAL_DONE
