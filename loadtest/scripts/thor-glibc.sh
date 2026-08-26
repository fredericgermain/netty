#!/bin/bash
# Every number in this branch came from an Alpine (musl) container. Before any of it goes upstream
# the size cliff needs one glibc data point, because "reproduces on the JRE image most people run"
# and "musl-specific" are different reports. Same cell as the 64 KB baseline, corrected pinning,
# image swapped.
set -u
JAR=/home/fred/tls-matrix/loadtest-pin.jar
IMG=${1:-eclipse-temurin:21-jdk}
DUR=10
PAY=65536
CONNS=2000
ROUNDS=5
TAG=glibc

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT image=$IMG payload=$PAY connections=$CONNS"

one() {  # one <transport>
  local t=$1
  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    printf '%-11s' SRVFAIL
    docker logs "$name" 2>&1 | tail -3
    docker rm -f "$name" >/dev/null 2>&1; return
  fi
  timeout 150 docker run --rm --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 > /tmp/$TAG.out 2>&1
  local rps
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  printf '%-11s' "${rps:-CLIFAIL}"
  docker rm -f "$name" >/dev/null 2>&1
}

echo "round  epoll      io_uring"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one epoll
  one io_uring
  echo
done
echo GLIBC_DONE
