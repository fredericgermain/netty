#!/usr/bin/env bash
# C control experiment: frevib's io_uring echo server vs frevib's epoll echo server,
# driven by rust_echo_bench, on the netty test host.
#
# Usage: run-matrix.sh stock|big <rounds> <duration-seconds>
#
#   stock  upstream binaries, upstream payloads (128/512/1000 B) -- the reproduction run
#   big    both servers' MAX_MESSAGE_LEN raised identically, payloads 1K/8K/64K -- the
#          sweep that lines up against netty's size-dependent deficit
#
# The two transports alternate within every round and the leading transport swaps each
# round, so neither machine drift nor within-round warmup lands on the axis under test.

set -u

. "$(dirname "$0")/bench-lib.sh"

PHASE="${1:-stock}"
ROUNDS="${2:-5}"
DURATION="${3:-12}"

IMAGE=iouring-control:latest
SRV_CPUS=0,1,4,5   # physical cores 0 and 1 with their SMT siblings
CLI_CPUS=2,3,6,7   # physical cores 2 and 3 with their SMT siblings
SRV_NAME=cctl-srv
CLI_NAME=cctl-cli

case "$PHASE" in
  stock)
    IOURING_BIN=/opt/bin/io_uring_echo_server_stock
    EPOLL_BIN=/opt/bin/epoll_echo_server_stock
    CLIENT_BIN=/opt/bin/echo_bench_stock
    LENGTHS="128 512 1000"
    CONNS="1 50 300 1000"
    ;;
  big)
    IOURING_BIN=/opt/bin/io_uring_echo_server_big
    EPOLL_BIN=/opt/bin/epoll_echo_server_big
    CLIENT_BIN=/opt/bin/echo_bench_loop
    LENGTHS="1024 8192 65536"
    CONNS="50 300"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

OUT="$HOME/c-control/results-${PHASE}.tsv"
LOG="$HOME/c-control/run-${PHASE}.log"
: > "$LOG"
if [ ! -s "$OUT" ]; then
  printf 'phase\tround\ttransport\tbytes\tconns\treqs_per_sec\ttotal_reqs\ttotal_resps\tthrottle_d0123\tsrv_mhz\tcli_mhz\tgovernor\tnotes\n' > "$OUT"
fi

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

cleanup() {
  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  docker ps -aq --filter "name=${CLI_NAME}" | xargs -r docker rm -f >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# An orphaned process has squatted 19999 for hours before now, so never assume a port.
find_free_port() {
  local p
  for p in $(seq 19990 20050); do
    [ "$p" = 19999 ] && continue
    if ! ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

start_server() {
  local bin="$1" port="$2"
  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  docker run -d --rm --name "$SRV_NAME" \
    --network=host \
    --security-opt seccomp=unconfined \
    --cpuset-cpus="$SRV_CPUS" \
    "$IMAGE" "$bin" "$port" >/dev/null 2>&1 || return 1

  local i
  for i in $(seq 1 50); do
    if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
      return 0
    fi
    # The io_uring server exits immediately if the ring or buffer selection is
    # unavailable, which must be reported rather than silently measured as zero.
    if [ "$(docker inspect -f '{{.State.Status}}' "$SRV_NAME" 2>/dev/null)" != "running" ]; then
      log "  SERVER DIED: $(docker logs "$SRV_NAME" 2>&1 | head -5)"
      return 1
    fi
    sleep 0.2
  done
  log "  SERVER NEVER LISTENED on $port"
  return 1
}

run_cell() {
  local transport="$1" bin="$2" round="$3" len="$4" conns="$5"

  local port
  port=$(find_free_port) || { log "  no free port in 19990-20050"; return 1; }

  if ! start_server "$bin" "$port"; then
    printf '%s\t%s\t%s\t%s\t%s\t\t\t\t\t\t\t%s\tserver-start-failed\n' \
      "$PHASE" "$round" "$transport" "$len" "$conns" "$(governor_now)" >> "$OUT"
    return 1
  fi

  # A unique client name per invocation: `timeout` kills the docker CLI but leaves the container
  # running, and the next run then fails with exit 125 against a name still held by its own orphan.
  local raw cname thr_before thr_after thr_d freqfile fsamp srvcli
  cname="${CLI_NAME}-$$-${RANDOM}"
  thr_before=$(throttle_snapshot)
  freqfile=$(mktemp)
  fsamp=$(freq_sampler_start "$freqfile" 2)
  raw=$(timeout $((DURATION + 60)) docker run --rm --name "$cname" \
          --network=host \
          --cpuset-cpus="$CLI_CPUS" \
          "$IMAGE" "$CLIENT_BIN" \
          -a "127.0.0.1:$port" -c "$conns" -l "$len" -t "$DURATION" 2>&1)
  local rc=$?
  freq_sampler_stop "$fsamp"
  local foreign_after
  foreign_after=$(foreign_containers)
  thr_after=$(throttle_snapshot)
  thr_d=$(throttle_delta "$thr_before" "$thr_after")
  srvcli=$(freq_summary "$freqfile")
  rm -f "$freqfile"
  docker rm -f "$cname" >/dev/null 2>&1

  echo "--- $transport r$round len=$len conns=$conns port=$port rc=$rc" >> "$LOG"
  echo "$raw" >> "$LOG"

  local speed reqs resps notes
  speed=$(echo "$raw" | sed -n 's/^Speed: \([0-9]*\) request\/sec.*/\1/p')
  reqs=$(echo "$raw" | sed -n 's/^Requests: \([0-9]*\)/\1/p')
  resps=$(echo "$raw" | sed -n 's/^Responses: \([0-9]*\)/\1/p')
  notes=""
  [ "$rc" -ne 0 ] && notes="client-rc=$rc"
  # A surviving "Read error!" means connections dropped out mid-run and the throughput
  # figure is drawn from fewer clients than requested.
  if echo "$raw" | grep -q 'Read error'; then
    notes="${notes}${notes:+;}read-errors=$(echo "$raw" | grep -c 'Read error')"
  fi
  [ -z "$speed" ] && { speed=""; notes="${notes}${notes:+;}no-speed-line"; }
  case "$thr_d" in
    *[1-9]*) notes="${notes}${notes:+;}THROTTLED=$thr_d" ;;
  esac
  [ -n "$foreign_after" ] && notes="${notes}${notes:+;}CONTENDED=${foreign_after% }"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PHASE" "$round" "$transport" "$len" "$conns" "$speed" "$reqs" "$resps" \
    "$thr_d" "${srvcli%%/*}" "${srvcli##*/}" "$(governor_now)" "$notes" >> "$OUT"
  log "  r$round $transport len=$len c=$conns -> ${speed:-FAIL} req/s thr=$thr_d mhz=$srvcli ${notes:+($notes)}"

  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  # Give TIME_WAIT sockets from a 1000-connection run a moment before the next bind.
  sleep 2
}

log "phase=$PHASE rounds=$ROUNDS duration=${DURATION}s lengths=[$LENGTHS] conns=[$CONNS]"
log "governor=$(governor_now) throttle_at_start=[$(throttle_snapshot)]"
log "idle check: $(vmstat 1 2 | tail -1 | awk '{print "us="$13" sy="$14" id="$15}')"

if ! wait_for_quiet 85 5400; then
  log "ABORT: host never became quiet, refusing to produce numbers"
  exit 3
fi
log "host quiet, starting"

for round in $(seq 1 "$ROUNDS"); do
  log "=== round $round ==="
  wait_for_quiet 85 5400 || { log "ABORT mid-run: host busy"; exit 3; }
  for len in $LENGTHS; do
    for conns in $CONNS; do
      if [ $((round % 2)) -eq 1 ]; then
        run_cell epoll   "$EPOLL_BIN"   "$round" "$len" "$conns"
        run_cell iouring "$IOURING_BIN" "$round" "$len" "$conns"
      else
        run_cell iouring "$IOURING_BIN" "$round" "$len" "$conns"
        run_cell epoll   "$EPOLL_BIN"   "$round" "$len" "$conns"
      fi
    done
  done
  log "idle after round $round: $(vmstat 1 2 | tail -1 | awk '{print "id="$15}')"
done

log "done, results in $OUT"
