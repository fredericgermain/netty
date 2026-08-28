#!/bin/bash
# What sizes does quiche allocate, and how evenly?
#
# The .so is stripped and netty unlinks it after extracting to /tmp, so call sites will not
# symbolise. Sizes are the next best evidence and are arguably more useful for the pooling question:
# a tight cluster of a few fixed sizes is poolable, a broad spread is not.
#
# Also records the free rate. If allocations and frees balance during steady state then the working
# set is stable and the churn is pure overhead, which is exactly the case a pool or an arena removes.
set -u
JAR=/tmp/loadtest-published.jar
IMG=alpine-jdk-musl-alloc
CONNS=500
TRACE_SECS=${TRACE_SECS:-3}

PORT=0
for p in $(seq 20350 20400); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

docker rm -f s-srv s-cli >/dev/null 2>&1
docker run -d --rm --name s-srv --network=host --cpuset-cpus=0,1,4,5 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
    --payload=1024 --threads=4 >/dev/null 2>&1
for i in $(seq 1 60); do docker logs s-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
docker logs s-srv 2>&1 | grep -q '^READY' || { echo SERVER_FAILED; docker rm -f s-srv >/dev/null 2>&1; exit 1; }
PID=$(docker inspect -f '{{.State.Pid}}' s-srv)
MUSL="/proc/$PID/root/lib/ld-musl-x86_64.so.1"

docker run -d --rm --name s-cli --network=host --cpuset-cpus=2,3,6,7 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
    --connections=$CONNS --duration=90 --payload=1024 --threads=4 >/dev/null 2>&1
sleep 8

echo "pid=$PID  tracing ${TRACE_SECS}s"
# arg0 of malloc is the requested size. Log2 histogram first for shape, then exact counts for the
# hot sizes, since a pool needs exact size classes rather than buckets.
sudo -n timeout $((TRACE_SECS + 10)) bpftrace -e "
uprobe:$MUSL:malloc /pid == $PID/ { @sz = hist(arg0); @exact[arg0] = count(); @m = count(); }
uprobe:$MUSL:free   /pid == $PID/ { @f = count(); }
uprobe:$MUSL:realloc /pid == $PID/ { @r = count(); }
interval:s:$TRACE_SECS { exit(); }
" 2>/dev/null > /tmp/sizes.txt

docker rm -f s-srv s-cli >/dev/null 2>&1

echo "=== malloc / free / realloc counts over ${TRACE_SECS}s"
grep -E "^@m:|^@f:|^@r:" /tmp/sizes.txt
echo
echo "=== size distribution (log2)"
sed -n '/@sz:/,/^$/p' /tmp/sizes.txt | head -22
echo "=== top exact sizes"
grep -oE '@exact\[[0-9]+\]: [0-9]+' /tmp/sizes.txt | sed 's/@exact\[//; s/\]:/ /' \
  | sort -k2 -rn | head -12
echo SIZES_DONE
