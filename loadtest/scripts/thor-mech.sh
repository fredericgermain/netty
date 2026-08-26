#!/bin/bash
# Discriminate the two candidate mechanisms for the io_uring size cliff, at one payload, with the
# corrected physical-core pinning throughout.
#
# Write path: netty's io_uring transport never consumes getWriteSpinCount(), so a partial write
# costs a POLL_ADD round trip plus a fresh SQE where epoll just calls write() again, up to 16
# times, in the same event-loop turn. Partial writes per message grow with payload against the
# socket's send buffer, so if this is the mechanism the deficit should track SO_SNDBUF in both
# directions on io_uring and stay flat on epoll. thor autotunes tcp_wmem from 16 KB up to 4 MB;
# setting SO_SNDBUF pins it (kernel doubles the requested value) and wmem_max=1MB caps the request,
# so 64 KB and 1 MB give fixed 128 KB and 2 MB buffers.
#
# Read path / footprint: a completion-based transport commits the receive buffer at submit time.
# Capping the adaptive guess at 16 KB shrinks the committed footprint 4x below the default 64 KB
# ceiling; raising it to 512 KB lets one read take a whole frame but grows the footprint 8x. The
# footprint mechanism predicts the cap helps io_uring; a per-operation mechanism predicts the
# opposite, because smaller reads mean more operations.
#
# EXTRA exists so the whole discriminator can be re-run with --prealloc, which is the only way to
# tell whether the read-count conclusion below was a property of netty or of a load generator that
# memset its payload on every request. Both sides get it, so a cell is never half-applied.
set -u
JAR=${JAR:-/home/fred/tls-matrix/loadtest-pin.jar}
IMG=eclipse-temurin:21-jdk-alpine
DUR=${DUR:-10}
EXTRA=${EXTRA:-}
PAY=${1:?payload bytes}
CONNS=${2:?connections}
ROUNDS=${3:-5}
TAG=${4:-mech}

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT payload=$PAY connections=$CONNS rounds=$ROUNDS"

DETAIL=/tmp/$TAG-detail.log
ERRS=/tmp/$TAG-err.log
: > "$DETAIL"; : > "$ERRS"

one() {  # one <label> <transport> <extra server/client args or ->
  local label=$1 t=$2 xargs=$3
  [ "$xargs" = "-" ] && xargs=""
  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 --payload=$PAY --connections=$CONNS $EXTRA $xargs >/dev/null
  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    printf '%-11s' SRVFAIL
    docker logs "$name" 2>&1 | tail -3 >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi

  timeout 200 docker run --rm --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 $EXTRA $xargs \
      > /tmp/$TAG.out 2>&1

  local rps mem
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  # EXTRA is only ever used to add --prealloc, and a cell that silently ran without it would be
  # worse than no cell at all.
  if echo "$EXTRA" | grep -q prealloc && ! grep -q 'prealloc=true' /tmp/$TAG.out; then
    printf '%-11s' CLIMODE
    head -3 /tmp/$TAG.out >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi
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

echo "round  ep-def     ur-def     ep-s64K    ur-s64K    ep-s1M     ur-s1M     ur-r16K    ur-r512K"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one ep-def   epoll    -
  one ur-def   io_uring -
  one ep-s64K  epoll    --sndbuf=65536
  one ur-s64K  io_uring --sndbuf=65536
  one ep-s1M   epoll    --sndbuf=1048576
  one ur-s1M   io_uring --sndbuf=1048576
  one ur-r16K  io_uring --rcvbuf-max=16384
  one ur-r512K io_uring --rcvbuf-max=524288
  echo
done
echo "--- detail:"
cat "$DETAIL"
echo "--- errors:"
cat "$ERRS"
echo MECH_DONE
