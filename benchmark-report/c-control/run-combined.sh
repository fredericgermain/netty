#!/usr/bin/env bash
# C echo servers and netty, all four arms measured inside the same round.
#
# Usage: run-combined.sh <rounds> <duration-seconds>
#
# Running the C pair and netty as separate sweeps does not work on this host. thor is a mobile
# i5-10300H and its package clock collapses from ~2815 MHz to ~1800 MHz after roughly twenty
# minutes of sustained load, without incrementing any core_throttle_count, because it is PL1
# power limiting rather than thermal core throttling. A sweep taken before the collapse and one
# taken after differ by 35% in absolute throughput, so comparing netty's ratio from one against
# the C pair's ratio from the other measures the power budget, not the transports.
#
# Interleaving all four arms inside every round makes drift common-mode: whatever the clock is
# doing, all four arms see the same thing within a few seconds of each other, and the ratios stay
# comparable even as the absolute numbers sag. The arm order rotates by round so no arm is
# permanently first, and every cell records the clock it was actually taken at.

set -u

. "$(dirname "$0")/bench-lib.sh"

ROUNDS="${1:-5}"
DURATION="${2:-12}"
WARMUP="${WARMUP:-12}"
LENGTHS="${LENGTHS:-1024 8192 65536}"
CONNS="${CONNS:-50 300}"
NETTY_THREADS="${NETTY_THREADS:-4}"
# Below this the cell is taken in the power-limited regime and is not comparable to one taken
# above it. Rounds wait for recovery; cells that sag anyway are flagged in the row.
MIN_MHZ="${MIN_MHZ:-2600}"

JAR="$HOME/c-control/netty-loadtest.jar"
NETTY_IMAGE=eclipse-temurin:21-jdk-alpine
C_IMAGE=iouring-control:latest
CLI_IMAGE=iouring-control:latest
CLIENT_BIN=/opt/bin/echo_bench_loop
SRV_CPUS=0,1,4,5
CLI_CPUS=2,3,6,7
SRV_NAME=xctl-srv
CLI_NAME=xctl-cli

OUT="$HOME/c-control/results-combined.tsv"
LOG="$HOME/c-control/run-combined.log"
: > "$LOG"
if [ ! -s "$OUT" ]; then
  printf 'round\tarm\tbytes\tconns\treqs_per_sec\ttotal_reqs\ttotal_resps\tthrottle_d0123\tsrv_mhz\tcli_mhz\tgovernor\tnotes\n' > "$OUT"
fi

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

cleanup() {
  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  docker ps -aq --filter "name=${CLI_NAME}" | xargs -r docker rm -f >/dev/null 2>&1
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

# Idles until the package clock recovers, so every round starts from comparable silicon.
wait_for_clock() {
  local min_mhz="$1" max_wait="${2:-900}" waited=0 mhz
  while :; do
    mhz=$(awk '{s+=$1} END {printf "%d", s/NR/1000}' \
          /sys/devices/system/cpu/cpu[0-7]/cpufreq/scaling_cur_freq 2>/dev/null)
    [ "${mhz:-0}" -ge "$min_mhz" ] && return 0
    [ "$waited" -ge "$max_wait" ] && { log "  clock stuck at ${mhz}MHz after ${waited}s, proceeding and flagging"; return 1; }
    sleep 20
    waited=$((waited + 20))
  done
}

SRV_CID=""
start_server() {
  local arm="$1" port="$2"
  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  case "$arm" in
    c-epoll)
      SRV_CID=$(docker run -d --rm --name "$SRV_NAME" --network=host \
        --security-opt seccomp=unconfined --cpuset-cpus="$SRV_CPUS" \
        "$C_IMAGE" /opt/bin/epoll_echo_server_big "$port" 2>/dev/null) || return 1 ;;
    c-iouring)
      SRV_CID=$(docker run -d --rm --name "$SRV_NAME" --network=host \
        --security-opt seccomp=unconfined --cpuset-cpus="$SRV_CPUS" \
        "$C_IMAGE" /opt/bin/io_uring_echo_server_big "$port" 2>/dev/null) || return 1 ;;
    n-epoll|n-iouring)
      local t=epoll; [ "$arm" = n-iouring ] && t=io_uring
      SRV_CID=$(docker run -d --rm --name "$SRV_NAME" --network=host \
        --security-opt seccomp=unconfined --cpuset-cpus="$SRV_CPUS" \
        --ulimit nofile=65536:65536 --ulimit memlock=-1 \
        -v "$JAR:/app/lt.jar:ro" "$NETTY_IMAGE" \
        java -jar /app/lt.jar server --transport="$t" --tls=none --port="$port" \
          --threads="$NETTY_THREADS" --backlog=8192 --raw 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac

  assert_container_is "$SRV_CID" "$SRV_NAME" || { log "  container id mismatch for $arm"; return 1; }

  local i
  for i in $(seq 1 80); do
    case "$arm" in
      c-*) ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN && return 0 ;;
      n-*) if docker logs "$SRV_CID" 2>&1 | grep -q '^READY'; then
             docker logs "$SRV_CID" 2>&1 | grep -q 'raw=true' || {
               log "  $arm came up WITHOUT raw mode, refusing"; return 1; }
             return 0
           fi ;;
    esac
    if [ "$(docker inspect -f '{{.State.Status}}' "$SRV_CID" 2>/dev/null)" != "running" ]; then
      log "  $arm SERVER DIED: $(docker logs "$SRV_CID" 2>&1 | tail -2 | tr '\n' ' ')"
      return 1
    fi
    sleep 0.5
  done
  log "  $arm never became ready on $port"
  return 1
}

client() {
  local port="$1" conns="$2" len="$3" secs="$4"
  local cname="${CLI_NAME}-$$-${RANDOM}" rc
  timeout $((secs + 90)) docker run --rm --name "$cname" \
    --network=host --cpuset-cpus="$CLI_CPUS" \
    "$CLI_IMAGE" "$CLIENT_BIN" \
    -a "127.0.0.1:$port" -c "$conns" -l "$len" -t "$secs" 2>&1
  rc=$?
  docker rm -f "$cname" >/dev/null 2>&1
  return $rc
}

run_cell() {
  local arm="$1" round="$2" len="$3" conns="$4"
  local port
  port=$(find_free_port) || { log "  no free port"; return 1; }

  if ! start_server "$arm" "$port"; then
    printf '%s\t%s\t%s\t%s\t\t\t\t\t\t\t%s\tserver-start-failed\n' \
      "$round" "$arm" "$len" "$conns" "$(governor_now)" >> "$OUT"
    docker rm -f "$SRV_NAME" >/dev/null 2>&1
    return 1
  fi

  # Every arm gets the same warmup, netty because a cold JVM measures the JIT, and the C servers
  # so that all four arms deposit the same amount of heat before their measured window.
  client "$port" "$conns" "$len" "$WARMUP" >> "$LOG" 2>&1

  local raw rc thr_before thr_after thr_d freqfile fsamp srvcli foreign_after
  thr_before=$(throttle_snapshot)
  freqfile=$(mktemp)
  fsamp=$(freq_sampler_start "$freqfile" 2)
  raw=$(client "$port" "$conns" "$len" "$DURATION")
  rc=$?
  freq_sampler_stop "$fsamp"
  foreign_after=$(foreign_containers)
  thr_after=$(throttle_snapshot)
  thr_d=$(throttle_delta "$thr_before" "$thr_after")
  srvcli=$(freq_summary "$freqfile")
  rm -f "$freqfile"

  echo "--- $arm r$round len=$len conns=$conns port=$port rc=$rc" >> "$LOG"
  echo "$raw" >> "$LOG"

  local speed reqs resps notes srv_mhz
  speed=$(echo "$raw" | sed -n 's/^Speed: \([0-9]*\) request\/sec.*/\1/p')
  reqs=$(echo "$raw" | sed -n 's/^Requests: \([0-9]*\)/\1/p')
  resps=$(echo "$raw" | sed -n 's/^Responses: \([0-9]*\)/\1/p')
  srv_mhz="${srvcli%%/*}"
  notes=""
  [ "$rc" -ne 0 ] && notes="client-rc=$rc"
  echo "$raw" | grep -q 'Read error' && notes="${notes}${notes:+;}read-errors"
  echo "$raw" | grep -q 'Connect error' && notes="${notes}${notes:+;}connect-errors"
  [ -z "$speed" ] && notes="${notes}${notes:+;}no-speed-line"
  case "$thr_d" in *[1-9]*) notes="${notes}${notes:+;}THROTTLED=$thr_d" ;; esac
  [ -n "$foreign_after" ] && notes="${notes}${notes:+;}CONTENDED=${foreign_after% }"
  # Records the power-limited regime explicitly rather than letting it hide in the spread.
  if [ "${srv_mhz:-0}" != "NA" ] && [ "${srv_mhz:-0}" -lt "$MIN_MHZ" ] 2>/dev/null; then
    notes="${notes}${notes:+;}LOWCLOCK=${srv_mhz}MHz"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$arm" "$len" "$conns" "$speed" "$reqs" "$resps" \
    "$thr_d" "$srv_mhz" "${srvcli##*/}" "$(governor_now)" "$notes" >> "$OUT"
  log "  r$round $(printf '%-10s' "$arm") len=$len c=$conns -> ${speed:-FAIL} req/s mhz=$srvcli ${notes:+($notes)}"

  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  sleep 2
}

ARMS="c-epoll c-iouring n-epoll n-iouring"

log "combined run: rounds=$ROUNDS warmup=${WARMUP}s measure=${DURATION}s netty_threads=$NETTY_THREADS"
log "lengths=[$LENGTHS] conns=[$CONNS] min_mhz=$MIN_MHZ"
log "governor=$(governor_now) throttle_at_start=[$(throttle_snapshot)]"

if ! wait_for_quiet 85 5400; then
  log "ABORT: host never became quiet"
  exit 3
fi

for round in $(seq 1 "$ROUNDS"); do
  wait_for_quiet 85 5400 || { log "ABORT mid-run: host busy"; exit 3; }
  log "=== round $round (waiting for clock >= ${MIN_MHZ}MHz) ==="
  wait_for_clock "$MIN_MHZ" 900
  log "=== round $round starting, clock $(awk '{s+=$1} END {printf "%d", s/NR/1000}' /sys/devices/system/cpu/cpu[0-7]/cpufreq/scaling_cur_freq)MHz ==="

  for len in $LENGTHS; do
    for conns in $CONNS; do
      # Rotate which arm leads so no arm is permanently measured on the coolest silicon.
      local_arms=""
      i=0
      for a in $ARMS; do
        i=$((i + 1))
        if [ $i -gt $(( (round - 1) % 4 )) ]; then local_arms="$local_arms $a"; fi
      done
      i=0
      for a in $ARMS; do
        i=$((i + 1))
        if [ $i -le $(( (round - 1) % 4 )) ]; then local_arms="$local_arms $a"; fi
      done
      for a in $local_arms; do
        run_cell "$a" "$round" "$len" "$conns"
      done
    done
  done
done

log "done, results in $OUT"
