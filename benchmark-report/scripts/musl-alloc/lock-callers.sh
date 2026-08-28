#!/bin/bash
# Name the callers of musl's __lock during a QUIC load.
#
# Established: musl's mallocng lock is the mechanism behind the ~17% QUIC deficit on Alpine, proved
# by LD_PRELOAD of jemalloc removing it. What is still unnamed is WHICH call sites allocate, which
# is what would be needed to reduce the allocation rate rather than swap the allocator.
#
# ustack() is useless here: musl is built without frame pointers, so BPF's frame-pointer walk
# produces nothing above __lock. But at function ENTRY the return address is at [rsp] by the x86-64
# calling convention, so reading *(uint64*)reg("sp") gives the immediate caller exactly, with no
# unwinding at all. That is one frame rather than a stack, which is enough to answer "which library
# and which function calls the lock".
#
# Addresses are raw and per-process, so /proc/PID/maps is captured at the same moment and the
# resolution is done afterwards. Doing it that way keeps the probe cheap, which matters because
# __lock is hot and a uprobe on it perturbs timing heavily. Perturbation is acceptable here: it
# distorts how long things take, not who calls whom.
set -u
JAR=/tmp/loadtest-published.jar
IMG=alpine-jdk-musl-alloc
OUT=/tmp/lockcallers
CONNS=500
TRACE_SECS=${TRACE_SECS:-5}

rm -rf "$OUT"; mkdir -p "$OUT"

PORT=0
for p in $(seq 20170 20220); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

docker rm -f l-srv l-cli >/dev/null 2>&1
# Default allocator deliberately: the point is to observe mallocng being hit, so preloading a
# replacement here would trace the very thing that was shown to remove the symptom.
docker run -d --rm --name l-srv --network=host --cpuset-cpus=0,1,4,5 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
    --payload=1024 --threads=4 >/dev/null 2>&1
for i in $(seq 1 60); do docker logs l-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
docker logs l-srv 2>&1 | grep -q '^READY' || { echo "SERVER_FAILED"; docker rm -f l-srv >/dev/null 2>&1; exit 1; }
PID=$(docker inspect -f '{{.State.Pid}}' l-srv)

docker run -d --rm --name l-cli --network=host --cpuset-cpus=2,3,6,7 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
    --connections=$CONNS --duration=60 --payload=1024 --threads=4 >/dev/null 2>&1
sleep 8

MUSL="/proc/$PID/root/lib/ld-musl-x86_64.so.1"
echo "pid=$PID musl=$MUSL tracing ${TRACE_SECS}s"

# Snapshot the mappings while the process is alive; the addresses mean nothing without them.
sudo -n cat "/proc/$PID/maps" > "$OUT/maps.txt"

sudo -n timeout $((TRACE_SECS + 6)) bpftrace -e "
uprobe:$MUSL:__lock /pid == $PID/ {
    @caller[*(uint64*)reg(\"sp\")] = count();
}
interval:s:$TRACE_SECS { exit(); }
" > "$OUT/raw.txt" 2>"$OUT/err.txt"

docker rm -f l-srv l-cli >/dev/null 2>&1

echo "--- top raw caller addresses:"
grep -oE '@caller\[[0-9]+\]: [0-9]+' "$OUT/raw.txt" 2>/dev/null | sort -t: -k2 -rn | head -12
echo "--- probe errors, if any:"
head -3 "$OUT/err.txt" 2>/dev/null
echo "maps and raw counts left in $OUT"
echo LOCKCALLERS_DONE
