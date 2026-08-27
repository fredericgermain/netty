#!/usr/bin/env bash
# System-wide kernel profile of one netty cell per transport, to test why async-profiler accounts
# for epoll's kernel time almost exactly but under-reports io_uring's by roughly 3.5x.
#
# Usage: perf-probe.sh <payload-bytes> <connections> <seconds>
#
# The leading hypothesis is that NET_RX softirq work is charged to whichever task happens to be
# current, so it lands in that task's system time, but its stack is kernel-only and has no user
# frame to join to, so a JVM profiler walking from Java frames outward cannot attribute it and
# simply drops it. A JVM profiler cannot see this; a system-wide `perf record -a -g -e cycles:k`
# can, because it samples the kernel regardless of what user code sits underneath.
#
# What would confirm it: a large __do_softirq / net_rx_action subtree, attributed to the JVM's
# own threads rather than to a kernel thread, and materially larger under io_uring than epoll.
# What would refute it: softirq time roughly equal across transports, or concentrated in ksoftirqd
# (a separate task, whose time would never have been charged to the JVM in the first place).

set -u

. "$(dirname "$0")/bench-lib.sh"

PAY="${1:-1024}"
CONNS="${2:-50}"
SECS="${3:-12}"

JAR="$HOME/c-control/netty-loadtest.jar"
SRV_IMAGE=eclipse-temurin:21-jdk-alpine
CLI_IMAGE=iouring-control:latest
SRV_CPUS=0,1,4,5
CLI_CPUS=2,3,6,7
OUTDIR="$HOME/c-control/perf"
mkdir -p "$OUTDIR"

cleanup() {
  docker rm -f pprobe-srv >/dev/null 2>&1
  docker ps -aq --filter "name=pprobe-cli" | xargs -r docker rm -f >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

find_free_port() {
  local p
  for p in $(seq 19990 20050); do
    [ "$p" = 19999 ] && continue
    if ! ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then echo "$p"; return 0; fi
  done
  return 1
}

one_transport() {
  local transport="$1"
  local port cid data
  port=$(find_free_port) || { echo "no free port"; return 1; }
  data="$OUTDIR/$transport.data"

  docker rm -f pprobe-srv >/dev/null 2>&1
  cid=$(docker run -d --rm --name pprobe-srv \
    --network=host --security-opt seccomp=unconfined --cpuset-cpus="$SRV_CPUS" \
    --ulimit nofile=65536:65536 --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" "$SRV_IMAGE" \
    java -jar /app/lt.jar server --transport="$transport" --tls=none --port="$port" \
      --threads=4 --backlog=8192 --raw 2>/dev/null) || return 1

  local i
  for i in $(seq 1 80); do
    docker logs "$cid" 2>&1 | grep -q '^READY' && break
    sleep 0.5
  done
  docker logs "$cid" 2>&1 | grep -q 'raw=true' || { echo "$transport: not raw mode"; return 1; }

  # Warm the JVM first: profiling a cold JVM measures the JIT, not the transport.
  timeout $((SECS + 60)) docker run --rm --name "pprobe-cli-w-$RANDOM" \
    --network=host --cpuset-cpus="$CLI_CPUS" "$CLI_IMAGE" /opt/bin/echo_bench_loop \
    -a "127.0.0.1:$port" -c "$CONNS" -l "$PAY" -t 15 >/dev/null 2>&1

  # Kernel-only cycles, system-wide, for exactly the steady window the client is driving.
  sudo perf record -a -g -e cycles:k -F 499 -o "$data" -- sleep "$SECS" >/dev/null 2>&1 &
  local perfpid=$!

  local cname="pprobe-cli-$RANDOM"
  timeout $((SECS + 60)) docker run --rm --name "$cname" \
    --network=host --cpuset-cpus="$CLI_CPUS" "$CLI_IMAGE" /opt/bin/echo_bench_loop \
    -a "127.0.0.1:$port" -c "$CONNS" -l "$PAY" -t "$SECS" > "$OUTDIR/$transport.client.txt" 2>&1
  docker rm -f "$cname" >/dev/null 2>&1

  wait $perfpid 2>/dev/null
  sudo chown "$(id -u):$(id -g)" "$data" 2>/dev/null

  docker logs "$cid" 2>&1 | grep SERVERCPU | tail -1 > "$OUTDIR/$transport.servercpu.txt"
  docker rm -f pprobe-srv >/dev/null 2>&1
  sleep 3

  {
    echo "===== $transport : payload=$PAY conns=$CONNS secs=$SECS ====="
    echo "--- client ---"
    grep -E '^Speed|^Requests' "$OUTDIR/$transport.client.txt"
    echo "--- server counters ---"
    cat "$OUTDIR/$transport.servercpu.txt"
    echo "--- total samples ---"
    perf report -i "$data" --stdio 2>/dev/null | grep -E '^# Samples|^# Event count' | head -2
    echo "--- top kernel symbols (flat) ---"
    perf report -i "$data" --stdio --no-children -g none --percent-limit 0.5 2>/dev/null |
      grep -E '^\s+[0-9]' | head -25
    echo "--- share by comm ---"
    perf report -i "$data" --stdio --no-children -g none --sort comm --percent-limit 0.5 2>/dev/null |
      grep -E '^\s+[0-9]' | head -15
    echo "--- softirq subtree (inclusive, by caller) ---"
    perf report -i "$data" --stdio --children --sort sym --percent-limit 0.3 2>/dev/null |
      grep -iE 'do_softirq|net_rx_action|napi|tcp_v4_rcv|ip_rcv|__netif_receive|process_backlog|loopback' | head -20
    echo "--- softirq share attributed per comm ---"
    perf report -i "$data" --stdio --children --sort comm,sym --percent-limit 0.3 2>/dev/null |
      grep -iE 'do_softirq|net_rx_action|process_backlog' | head -20
    echo
  } >> "$OUTDIR/summary.txt"
}

if ! wait_for_quiet 85 5400; then
  echo "host never became quiet, refusing to profile" >&2
  exit 3
fi

: > "$OUTDIR/summary.txt"
{
  echo "perf probe: $(date -u +%F' '%T) governor=$(governor_now)"
  echo "throttle_at_start=[$(throttle_snapshot)]"
  echo "perf_event_paranoid=$(sysctl -n kernel.perf_event_paranoid) kptr_restrict=$(sysctl -n kernel.kptr_restrict)"
  echo
} >> "$OUTDIR/summary.txt"

for t in epoll io_uring; do
  echo "profiling $t ..."
  one_transport "$t"
done

echo "done: $OUTDIR/summary.txt"
