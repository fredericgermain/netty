#!/bin/bash
# Where is io_uring's kernel time hiding?
#
# The counters and the profile disagree by 3.5x for io_uring and agree to within 2 points for epoll.
# io_uring burns 66.5% of its CPU as system time, yet only 18.8% of its perf samples land on a
# kernel frame. Something is accruing system time to the process that async-profiler cannot sample.
#
# The candidate is io_wq: when io_uring cannot complete an operation inline it punts the work to
# kernel worker threads named iou-wrk-*. Those threads belong to the process, so their CPU shows up
# in /proc/self/stat and in the per-task sum the load test already reports, but a JVM profiler never
# attaches to them because they are not Java threads and did not exist when the agent started.
#
# If that is what is happening it is not merely a measurement artefact, it is the finding: punting
# to a worker means the operation is NOT being completed inline, which is the whole point of the
# ring, and it costs a thread handoff per operation.
#
# epoll is the control. It has no worker threads by construction, so it should show none.
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=20

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

# Thread census by name, plus the CPU those threads have burned. Fields 14/15 of /proc/<t>/stat are
# utime/stime in clock ticks; parsed after the last ')' because comm is parenthesised and can hold
# spaces. Grouped by a name with its trailing digits stripped, so the ten thousand iou-wrk-123-456
# threads collapse into one row instead of ten thousand.
census() {
  local pid=$1
  local label=$2
  [ -d "/proc/$pid" ] || { echo "  $label: pid $pid gone"; return; }
  echo "  --- $label (pid $pid)"
  for t in /proc/$pid/task/*; do
    [ -r "$t/stat" ] || continue
    local line comm rest
    line=$(cat "$t/stat" 2>/dev/null) || continue
    comm=$(echo "$line" | sed -E 's/^[0-9]+ \((.*)\) .*/\1/')
    rest=$(echo "$line" | sed -E 's/^.*\) . //')
    local u s
    u=$(echo "$rest" | cut -d' ' -f12)
    s=$(echo "$rest" | cut -d' ' -f13)
    echo "$(echo "$comm" | sed -E 's/[0-9-]+$//') $u $s"
  done | awk '{n[$1]++; u[$1]+=$2; s[$1]+=$3}
              END {for (k in n) printf "      %-24s threads=%-6d utimeMs=%-8d stimeMs=%d\n",
                                        k, n[k], u[k]*10, s[k]*10}' | sort -k3 -t= -rn
}

cell() {
  local t=$1
  local name="iowq-$t"
  echo "===== $t"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "$t: SERVER FAILED"; return; }

  timeout 180 docker run -d --rm --name "iowq-c-$t" --network=host --cpuset-cpus=4-7 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 >/dev/null

  # Census mid-steady, once both sides are established and running flat out.
  for i in $(seq 1 40); do docker logs "iowq-c-$t" 2>&1 | grep -q '^RAMP' && break; sleep 0.5; done
  sleep 8
  local spid cpid
  spid=$(pgrep -f "lt.jar server --transport=$t" | head -1)
  cpid=$(pgrep -f "lt.jar client --transport=$t" | head -1)
  census "${spid:-0}" "server"
  census "${cpid:-0}" "client"

  docker wait "iowq-c-$t" >/dev/null 2>&1
  docker logs "iowq-c-$t" 2>&1 | grep -E '^STEADY|^CLIENTCPU'
  docker rm -f "$name" "iowq-c-$t" >/dev/null 2>&1
}

cell epoll
cell io_uring
echo IOWQ_DONE
