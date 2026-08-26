#!/bin/bash
# Stack the two levers that individually helped io_uring at 64 KB: a 512 KB receive-buffer ceiling
# (one read takes a whole frame, +17% alone) and a thread-local cache ceiling above it (the +15%
# lever, raised to 1 MB here because a 512 KB buffer bypasses a 256 KB cache). Both applied to
# epoll too: epoll's default adaptive ceiling is the same 64 KB, so if bigger reads help it
# equally the ratio goes nowhere and the "remediation" is just a tuning tip for both transports.
# The decomposition cell (512 KB guess without the cache raise) says whether the two levers are
# additive or the same effect counted twice.
set -u
JAR=/home/fred/tls-matrix/loadtest-pin.jar
IMG=eclipse-temurin:21-jdk-alpine
DUR=10
PAY=${1:-65536}
CONNS=${2:-2000}
ROUNDS=${3:-5}
TAG=${4:-stack}
CACHE1M=-Dio.netty.allocator.maxCachedBufferCapacity=1048576

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT payload=$PAY connections=$CONNS rounds=$ROUNDS"

DETAIL=/tmp/$TAG-detail.log
ERRS=/tmp/$TAG-err.log
: > "$DETAIL"; : > "$ERRS"

one() {  # one <label> <transport> <extra prog args or -> <extra jvm flags or ->
  local label=$1 t=$2 xargs=$3 jflags=$4
  [ "$xargs" = "-" ] && xargs=""
  [ "$jflags" = "-" ] && jflags=""
  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jflags -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 $xargs >/dev/null
  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    printf '%-11s' SRVFAIL
    docker logs "$name" 2>&1 | tail -3 >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi
  timeout 150 docker run --rm --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jflags -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 $xargs > /tmp/$TAG.out 2>&1
  local rps mem
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  mem=$(docker logs "$name" 2>&1 | grep -o 'usedDirectMb=[0-9]*' | cut -d= -f2 \
        | sort -n | awk 'NR==1{min=$1} {max=$1} END{if (NR) printf "%d-%dMB", min, max}')
  if [ -z "${rps:-}" ]; then
    printf '%-11s' CLIFAIL
    grep -iE 'exception|error' /tmp/$TAG.out | head -2 >> "$ERRS"
  else
    printf '%-11s' "$rps"
    echo "$label rps=$rps srvPool=$mem $(grep '^CLIENTCPU' /tmp/$TAG.out)" >> "$DETAIL"
  fi
  docker rm -f "$name" >/dev/null 2>&1
}

echo "round  ep-def     ur-def     ur-r512    ep-stack   ur-stack"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one ep-def   epoll    - -
  one ur-def   io_uring - -
  one ur-r512  io_uring --rcvbuf-max=524288 -
  one ep-stack epoll    --rcvbuf-max=524288 "$CACHE1M"
  one ur-stack io_uring --rcvbuf-max=524288 "$CACHE1M"
  echo
done
echo "--- detail:"
cat "$DETAIL"
echo "--- errors:"
cat "$ERRS"
echo STACK_DONE
