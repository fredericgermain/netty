#!/bin/bash
# Name the allocation sites that survive --prealloc, on both sides, rather than declaring victory
# from a counter.
#
# GarbageCollectorMXBean counts and ThreadMXBean bytes say HOW MUCH is allocated. They cannot say
# WHOSE code allocated it, and the branch has already been burned once by a number that looked
# authoritative and was not. async-profiler's JVMTI alloc event needs no privileges and attributes
# every sampled TLAB allocation to a stack, so any remaining site can be read off and assigned to
# netty or to the harness.
#
# Scope limit worth stating in any write-up: event=alloc sees the JAVA HEAP only. The original
# problem was pooled DIRECT memory, which is invisible here and to the GC both -- that is exactly
# how it hid. Read this next to the pooledChunks figures from thor-prealloc.sh, never on its own.
#
# glibc image, not Alpine: the async-profiler build on this host is linked against glibc. The branch
# has already measured that musl and glibc give the same transport ratio (epoll 39,149-42,217 and
# io_uring 19,155-19,893 on glibc, the same ~48% as Alpine), so this substitution does not move the
# thing being profiled.
set -u
JAR=${JAR:-/home/fred/tls-matrix/loadtest-prealloc.jar}
AP=${AP:-/home/fred/tls-matrix/async-profiler-4.5-linux-x64}
IMG=eclipse-temurin:21-jdk
OUT=${OUT:-/home/fred/tls-matrix/allocprof}
DUR=${DUR:-20}
PAY=${1:?payload bytes}
CONNS=${2:?connections}

mkdir -p "$OUT"
chmod 777 "$OUT"

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT payload=$PAY connections=$CONNS duration=$DUR out=$OUT"

# The ramp is inside the profile. At plaintext and these connection counts it is well under a
# second against a 20 s steady window, so it is a rounding error rather than a correction, but it
# is there and the numbers should not be quoted to the last percent because of it.
agent() {  # agent <file>
  echo "-agentpath:/ap/lib/libasyncProfiler.so=start,event=alloc,flat=40,total,file=/out/$1"
}

one() {  # one <label> <transport> <mode: base|pre>
  local label=$1 t=$2 mode=$3
  local flags=""
  [ "$mode" = pre ] && flags="--prealloc"

  local name="alloc-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" -v "$AP:/ap:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints "$(agent "$label-srv.txt")" \
      -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
      --threads=4 --backlog=8192 --payload=$PAY --connections=$CONNS $flags >/dev/null

  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  if [ "$ok" = 0 ]; then
    echo "$label SERVER FAILED"; docker logs "$name" 2>&1 | tail -5
    docker rm -f "$name" >/dev/null 2>&1; return
  fi

  timeout 240 docker run --rm --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" -v "$AP:/ap:ro" -v "$OUT:/out" "$IMG" \
    java -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints "$(agent "$label-cli.txt")" \
      -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 $flags \
      > "$OUT/$label-cli.out" 2>&1

  echo "== $label $(grep '^STEADY' "$OUT/$label-cli.out")"
  # SIGTERM, not kill -9: the agent writes its file from the JVM shutdown hook.
  docker stop -t 20 "$name" >/dev/null 2>&1
  docker rm -f "$name" >/dev/null 2>&1
}

one ep-base   epoll    base
one ur-base   io_uring base
one ep-pre    epoll    pre
one ur-pre    io_uring pre

for f in "$OUT"/*.txt; do
  echo
  echo "################ $f"
  head -30 "$f"
done
echo ALLOCPROF_DONE
