#!/bin/bash
# Does the io_uring deficit survive removing the harness's own allocation?
#
# Every transport comparison on this branch was taken with a load generator that memset a fresh
# payload buffer on every request, so its overhead scaled with payload -- the same axis the size
# cliff lives on. --prealloc removes that (see Prealloc.java). If the gap closes, the memory story
# was primary after all and the reads-per-message conclusion in loadtest/README.md is wrong. If it
# does not, the harness was noise on top of a real transport effect.
#
# --prealloc bundles three separable changes, so SET=decomp turns them on one at a time and the
# answer to "which one moved the number" is measured rather than assumed:
#
#   noalloc  the harness stops allocating per request: one pre-built frame, no LengthFieldPrepender,
#            void promises, per-loop histograms, no boxed due times
#   +warm    plus an arena warm-up that forces and pins the chunks the run will use
#   +fixed   plus a FixedRecvByteBufAllocator at the adaptive allocator's own 64 KB ceiling
#
# Cells are interleaved within a round so drift in machine state cannot map onto the axis under
# test, and every cell asserts that the mode it is labelled with actually took effect.
set -u
JAR=${JAR:-/home/fred/tls-matrix/loadtest-prealloc.jar}
IMG=eclipse-temurin:21-jdk-alpine
DUR=${DUR:-10}
SET=${SET:-main}
PAY=${1:?payload bytes}
CONNS=${2:?connections}
ROUNDS=${3:-5}
TAG=${4:-prealloc}

# -Xms == -Xmx so the heap does not grow mid-run, AlwaysPreTouch so its pages fault in before the
# ramp rather than during the steady window, and an explicit direct-memory ceiling so that limit is
# a stated condition rather than an accident of the heap setting. LoadTest aborts under --jvm-tuned
# if it does not find all three in its own argv.
JVMTUNE="-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:MaxDirectMemorySize=2g"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT payload=$PAY connections=$CONNS rounds=$ROUNDS duration=$DUR set=$SET jar=$JAR"

DETAIL=/tmp/$TAG-detail.log
ERRS=/tmp/$TAG-err.log
: > "$DETAIL"; : > "$ERRS"

# one <label> <transport> <mode> ; mode is base | noalloc | warm | pre | prejvm
one() {
  local label=$1 t=$2 mode=$3
  local jvm="" flags=""
  case "$mode" in
    base)    ;;
    noalloc) flags="--prealloc --no-warm --no-fixed-rcvbuf" ;;
    warm)    flags="--prealloc --no-fixed-rcvbuf" ;;
    pre)     flags="--prealloc" ;;
    prejvm)  flags="--prealloc"; jvm="$JVMTUNE"; flags="$flags --jvm-tuned" ;;
    *) echo "unknown mode $mode" >&2; exit 2 ;;
  esac

  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jvm -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 --payload=$PAY --connections=$CONNS $flags >/dev/null

  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    printf '%-11s' SRVFAIL
    { echo "== $label server did not start"; docker logs "$name" 2>&1 | tail -5; } >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi
  # A cell labelled prealloc that quietly was not would be worse than no cell at all.
  local ready; ready=$(docker logs "$name" 2>&1 | grep '^READY')
  if [ "$mode" != base ] && ! echo "$ready" | grep -q 'prealloc=true'; then
    printf '%-11s' SRVMODE
    echo "== $label server READY without prealloc: $ready" >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi

  timeout 200 docker run --rm --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java $jvm -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 $flags \
      > /tmp/$TAG.out 2>&1

  local rps mem chunks calloc salloc
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  if [ "$mode" != base ] && ! grep -q 'prealloc=true' /tmp/$TAG.out; then
    printf '%-11s' CLIMODE
    { echo "== $label client ran without prealloc"; head -3 /tmp/$TAG.out; } >> "$ERRS"
    docker rm -f "$name" >/dev/null 2>&1; return
  fi
  mem=$(docker logs "$name" 2>&1 | grep -o 'usedDirectMb=[0-9]*' | cut -d= -f2 \
        | sort -n | awk 'NR==1{min=$1} {max=$1} END{if (NR) printf "%d-%dMB", min, max}')
  chunks=$(docker logs "$name" 2>&1 | grep -o 'pooledChunks=[0-9]*' | cut -d= -f2 \
        | sort -n | awk 'NR==1{min=$1} {max=$1} END{if (NR) printf "%d-%d", min, max}')
  calloc=$(grep '^STEADY' /tmp/$TAG.out | grep -o 'allocBytesPerReq=[0-9.-]*' | cut -d= -f2)
  # Server heap allocation per request, from the consecutive pair of 2 s snapshots that served the
  # most requests -- that pair is inside the steady window by construction. The counters are
  # cumulative, so only the delta means anything.
  salloc=$(docker logs "$name" 2>&1 | grep '^SERVERCPU' | awk '
    { delete v; for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      if (NR > 1) { dr = v["requests"] - pr; if (dr > best) { best = dr; da = v["allocLoopKb"] - pa } }
      pr = v["requests"]; pa = v["allocLoopKb"] }
    END { if (best > 0) printf "%.1f", da * 1024 / best; else printf "-" }')

  if [ -z "${rps:-}" ]; then
    printf '%-11s' CLIFAIL
    { echo "== $label client failed"; grep -iE 'exception|error|abort' /tmp/$TAG.out | head -4; } >> "$ERRS"
  else
    printf '%-11s' "$rps"
    echo "$label rps=$rps srvPool=$mem srvChunks=$chunks cliAllocPerReq=$calloc srvAllocPerReq=$salloc $(grep '^CLIENTCPU' /tmp/$TAG.out)" >> "$DETAIL"
  fi
  docker rm -f "$name" >/dev/null 2>&1
}

if [ "$SET" = decomp ]; then
  echo "round  ep-base    ur-base    ep-noalloc ur-noalloc ep-warm    ur-warm    ep-pre     ur-pre"
  for r in $(seq 1 $ROUNDS); do
    printf '%-6s ' "$r"
    one ep-base    epoll    base
    one ur-base    io_uring base
    one ep-noalloc epoll    noalloc
    one ur-noalloc io_uring noalloc
    one ep-warm    epoll    warm
    one ur-warm    io_uring warm
    one ep-pre     epoll    pre
    one ur-pre     io_uring pre
    echo
  done
else
  echo "round  ep-base    ur-base    ep-pre     ur-pre     ep-prejvm  ur-prejvm"
  for r in $(seq 1 $ROUNDS); do
    printf '%-6s ' "$r"
    one ep-base   epoll    base
    one ur-base   io_uring base
    one ep-pre    epoll    pre
    one ur-pre    io_uring pre
    one ep-prejvm epoll    prejvm
    one ur-prejvm io_uring prejvm
    echo
  done
fi
echo "--- detail:"
cat "$DETAIL"
echo "--- errors:"
cat "$ERRS"
echo PREALLOC_DONE
