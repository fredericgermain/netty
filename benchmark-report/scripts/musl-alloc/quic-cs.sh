#!/bin/bash
# Does reducing allocation collapse musl's context-switch rate?
#
# The inference to test: musl's mallocng takes a global lock, four event loop threads allocating
# roughly 886 B/req contend on it, contention becomes futex syscalls, and those become context
# switches. Evidence so far is circumstantial but pointed -- __lock is musl's top frame, alloc_slot
# and get_meta sit just below it, futex_wake and futex_hash appear only on musl, and musl does 12.9x
# more context switches than glibc for the same work.
#
# --prealloc cuts per-request allocation from ~886 to ~637 B. If the lock is the mechanism, musl's
# context-switch count must fall materially. If it does not, the allocator is not what is driving
# the switches and the explanation is wrong, however good the frame names look.
#
# glibc is measured under the same two configurations as the control: its switch count should stay
# low and roughly flat either way, because per-thread arenas mean it was never contending.
set -u
JAR=/tmp/loadtest-published.jar
CONNS=500

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

cell() {  # cell <image> <tag> <extra>
  local img=$1; local tag=$2; shift 2
  local extra="$*"
  docker rm -f q-srv q-cli >/dev/null 2>&1

  docker run -d --rm --name q-srv --network=host --cpuset-cpus=0,1,4,5 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
      --payload=1024 --threads=4 $extra >/dev/null
  for i in $(seq 1 60); do docker logs q-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs q-srv 2>&1 | grep -q '^READY' || { echo "$tag SERVER_FAILED"; docker rm -f q-srv >/dev/null 2>&1; return; }

  local pid
  pid=$(pgrep -f "lt.jar server --protocol=quic.*--port=$PORT" | head -1)

  docker run -d --rm --name q-cli --network=host --cpuset-cpus=2,3,6,7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$img" \
    java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=25 --payload=1024 --threads=4 $extra >/dev/null
  sleep 6

  local stat
  stat=$(sudo -n perf stat -p "$pid" -e context-switches,page-faults,instructions -- sleep 8 2>&1)
  local cs pf ins
  cs=$(echo "$stat" | grep context-switches | awk '{print $1}')
  pf=$(echo "$stat" | grep -m1 page-faults | awk '{print $1}')
  ins=$(echo "$stat" | grep instructions | awk '{print $1}')
  printf '%-18s ctxSwitches=%-12s pageFaults=%-12s instructions=%s\n' "$tag" "$cs" "$pf" "$ins"

  docker rm -f q-srv q-cli >/dev/null 2>&1
  sleep 2
}

echo "port=$PORT conns=$CONNS -- perf stat over 8s of steady state, server side"
cell alpine-jdk-musldbg     "musl default"
cell alpine-jdk-musldbg     "musl prealloc" --prealloc
cell eclipse-temurin:21-jdk "glibc default"
cell eclipse-temurin:21-jdk "glibc prealloc" --prealloc
echo QUICCS_DONE
