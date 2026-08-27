#!/bin/bash
# Name the callers of musl's __lock, by ADDRESS rather than by name.
#
# First attempt failed silently: __lock and __unlock are LOCAL symbols in musl (nm shows "t", not
# "T"), so they exist only in the musl-dbg file and not in the dynamic symbol table that bpftrace
# resolves names against. bpftrace still printed "Attaching 1 probe..." and then never fired, which
# is exactly the silent-wrong-answer shape this project keeps running into: no error, no data, and
# nothing saying the probe matched nothing.
#
# The fix is the address form, uprobe:<lib>:<offset>, taking the offset from the debug file. A
# sanity probe on malloc (a real dynamic symbol) runs first, so that "zero samples" can be
# distinguished from "uprobes do not work on this process at all".
#
# Still reading the return address from [rsp] at entry rather than using ustack(), because musl has
# no frame pointers and a BPF stack walk gets nothing above the probe.
set -u
JAR=/tmp/loadtest-published.jar
IMG=alpine-jdk-musl-alloc
OUT=/tmp/lockcallers2
CONNS=500
TRACE_SECS=${TRACE_SECS:-4}

rm -rf "$OUT"; mkdir -p "$OUT"

PORT=0
for p in $(seq 20230 20280); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

docker rm -f l-srv l-cli >/dev/null 2>&1
docker run -d --rm --name l-srv --network=host --cpuset-cpus=0,1,4,5 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
    --payload=1024 --threads=4 >/dev/null 2>&1
for i in $(seq 1 60); do docker logs l-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
docker logs l-srv 2>&1 | grep -q '^READY' || { echo SERVER_FAILED; docker rm -f l-srv >/dev/null 2>&1; exit 1; }
PID=$(docker inspect -f '{{.State.Pid}}' l-srv)
MUSL="/proc/$PID/root/lib/ld-musl-x86_64.so.1"
DBG="/proc/$PID/root/usr/lib/debug/lib/ld-musl-x86_64.so.1.debug"

LOCK_OFF=$(sudo -n nm "$DBG" 2>/dev/null | awk '$3=="__lock"{print "0x"$1; exit}')
echo "pid=$PID  __lock offset=$LOCK_OFF"
[ -z "$LOCK_OFF" ] && { echo "could not find __lock offset"; docker rm -f l-srv >/dev/null 2>&1; exit 1; }

docker run -d --rm --name l-cli --network=host --cpuset-cpus=2,3,6,7 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
    --connections=$CONNS --duration=90 --payload=1024 --threads=4 >/dev/null 2>&1
sleep 8

sudo -n cat "/proc/$PID/maps" > "$OUT/maps.txt"

# Sanity probe: malloc IS a dynamic symbol, so if this fires and __lock does not, the difference is
# real rather than a broken probe.
echo "=== sanity: malloc call count over 2s"
sudo -n timeout 12 bpftrace -e "
uprobe:$MUSL:malloc /pid == $PID/ { @n = count(); }
interval:s:2 { exit(); }" 2>/dev/null | grep -E "@n:" || echo "  (malloc probe produced nothing)"

echo "=== __lock callers over ${TRACE_SECS}s, by return address"
sudo -n timeout $((TRACE_SECS + 8)) bpftrace -e "
uprobe:$MUSL:$LOCK_OFF /pid == $PID/ {
    @caller[*(uint64*)reg(\"sp\")] = count();
}
interval:s:$TRACE_SECS { exit(); }
" > "$OUT/raw.txt" 2>"$OUT/err.txt"

docker rm -f l-srv l-cli >/dev/null 2>&1
grep -oE '@caller\[[0-9]+\]: [0-9]+' "$OUT/raw.txt" 2>/dev/null | sed 's/@caller\[//; s/\]:/ /' \
  | sort -k2 -rn | head -14 > "$OUT/top.txt"
if [ -s "$OUT/top.txt" ]; then cat "$OUT/top.txt"; else echo "  (no samples)"; head -3 "$OUT/err.txt"; fi
echo "maps at $OUT/maps.txt"
echo LOCKCALLERS2_DONE
