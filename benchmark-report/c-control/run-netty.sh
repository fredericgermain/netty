#!/usr/bin/env bash
# Replicate the C control experiment against netty's transports.
#
# Usage: run-netty.sh t4|t1 <rounds> <duration-seconds>
#
# Same load generator, same payloads, same connection counts, same physical-core pinning and
# same interleaving as run-matrix.sh, so netty's epoll-vs-io_uring ratio can be read against the
# C pair's on the same axes. The only things that change are the server binary and the JVM warmup.
#
#   t4  --threads=4, the configuration every Part D netty result used
#   t1  --threads=1, structurally closest to the C servers, which are single-threaded
#
# Driving netty with rust_echo_bench rather than the project's own LoadTest client is the point:
# it is an independent load generator, which the harness has never been validated against, and it
# removes the client-side allocation confound that Part D had to correct for.

set -u

. "$(dirname "$0")/bench-lib.sh"

PHASE="${1:-t4}"
ROUNDS="${2:-5}"
DURATION="${3:-12}"
WARMUP="${WARMUP:-15}"

JAR="$HOME/c-control/netty-loadtest.jar"
SRV_IMAGE=eclipse-temurin:21-jdk-alpine
CLI_IMAGE=iouring-control:latest
CLIENT_BIN=/opt/bin/echo_bench_loop
SRV_CPUS=0,1,4,5
CLI_CPUS=2,3,6,7
SRV_NAME=nctl-srv
CLI_NAME=nctl-cli

case "$PHASE" in
  t4) THREADS=4; LENGTHS="1024 8192 65536"; CONNS="50 300" ;;
  t1) THREADS=1; LENGTHS="1024 65536";      CONNS="50" ;;
  *)  echo "unknown phase: $PHASE" >&2; exit 2 ;;
esac

OUT="$HOME/c-control/results-netty-${PHASE}.tsv"
LOG="$HOME/c-control/run-netty-${PHASE}.log"
: > "$LOG"
if [ ! -s "$OUT" ]; then
  printf 'phase\tthreads\tround\ttransport\tbytes\tconns\treqs_per_sec\ttotal_reqs\ttotal_resps\tthrottle_d0123\tsrv_mhz\tcli_mhz\tgovernor\tnotes\n' > "$OUT"
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

start_server() {
  local transport="$1" port="$2" len="$3" conns="$4"
  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  SRV_CID=$(docker run -d --rm --name "$SRV_NAME" \
    --network=host \
    --security-opt seccomp=unconfined \
    --cpuset-cpus="$SRV_CPUS" \
    --ulimit nofile=65536:65536 \
    --ulimit memlock=-1 \
    -v "$JAR:/app/lt.jar:ro" \
    "$SRV_IMAGE" \
    java -jar /app/lt.jar server \
      --transport="$transport" --tls=none --port="$port" \
      --threads="$THREADS" --backlog=8192 \
      --raw \
      --payload="$len" --connections="$conns" 2>/dev/null) || return 1

  # Logs read by name after a silently failed start return the previous container's output.
  if ! assert_container_is "$SRV_CID" "$SRV_NAME"; then
    log "  CONTAINER ID MISMATCH: started $SRV_CID but name $SRV_NAME resolves elsewhere"
    return 1
  fi

  # LoadTest aborts rather than falling back to NIO, so no READY line means the transport was
  # genuinely unavailable and the cell must be reported as a failure, not measured.
  local i
  for i in $(seq 1 80); do
    if docker logs "$SRV_CID" 2>&1 | grep -q '^READY'; then
      # rust_echo_bench speaks no framing protocol. If the server came up with the
      # length-prefixed pipeline it will never reply, and the cell would report a number drawn
      # from read timeouts rather than from netty. Refuse to measure that.
      if ! docker logs "$SRV_CID" 2>&1 | grep -q 'raw=true'; then
        log "  SERVER NOT IN RAW MODE, refusing to measure: $(docker logs "$SRV_CID" 2>&1 | grep '^READY' | head -1)"
        return 1
      fi
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Status}}' "$SRV_CID" 2>/dev/null)" != "running" ]; then
      log "  SERVER DIED: $(docker logs "$SRV_CID" 2>&1 | tail -3 | tr '\n' ' ')"
      return 1
    fi
    sleep 0.5
  done
  log "  SERVER NEVER READY on $port"
  return 1
}

client() {
  local port="$1" conns="$2" len="$3" secs="$4"
  # A unique name per invocation. `timeout` kills the docker CLI but leaves the container
  # running, so a fixed name survives its own run and the next `docker run` fails with exit 125
  # against the name still in use, which reads as a mysterious client failure rather than as the
  # orphan it is. Each run therefore gets its own name and removes it explicitly afterwards.
  local cname="${CLI_NAME}-$$-${RANDOM}"
  local rc
  timeout $((secs + 90)) docker run --rm --name "$cname" \
    --network=host --cpuset-cpus="$CLI_CPUS" \
    "$CLI_IMAGE" "$CLIENT_BIN" \
    -a "127.0.0.1:$port" -c "$conns" -l "$len" -t "$secs" 2>&1
  rc=$?
  docker rm -f "$cname" >/dev/null 2>&1
  return $rc
}

run_cell() {
  local label="$1" transport="$2" round="$3" len="$4" conns="$5"

  local port
  port=$(find_free_port) || { log "  no free port in 19990-20050"; return 1; }

  if ! start_server "$transport" "$port" "$len" "$conns"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t\t\t\t\t\t\t%s\tserver-start-failed\n' \
      "$PHASE" "$THREADS" "$round" "$label" "$len" "$conns" "$(governor_now)" >> "$OUT"
    return 1
  fi

  # A cold JVM spends the first seconds in the interpreter and in JIT compilation. The C servers
  # have no equivalent phase, so measuring netty without a warmup would compare netty's startup
  # against the C pair's steady state. The server survives the warmup, so only the client restarts.
  echo "--- WARMUP $label r$round len=$len conns=$conns port=$port" >> "$LOG"
  client "$port" "$conns" "$len" "$WARMUP" >> "$LOG" 2>&1

  # Throttle counters and clock are read around the measured window only. The warmup is allowed
  # to heat the part; what matters is whether the number being recorded was taken while throttled.
  local raw rc thr_before thr_after thr_d freqfile fsamp srvcli
  thr_before=$(throttle_snapshot)
  freqfile=$(mktemp)
  fsamp=$(freq_sampler_start "$freqfile" 2)
  raw=$(client "$port" "$conns" "$len" "$DURATION")
  rc=$?
  freq_sampler_stop "$fsamp"
  local foreign_after
  foreign_after=$(foreign_containers)
  thr_after=$(throttle_snapshot)
  thr_d=$(throttle_delta "$thr_before" "$thr_after")
  srvcli=$(freq_summary "$freqfile")
  rm -f "$freqfile"

  echo "--- MEASURED $label r$round len=$len conns=$conns port=$port rc=$rc" >> "$LOG"
  echo "$raw" >> "$LOG"
  echo "--- server tail:" >> "$LOG"
  docker logs "$SRV_CID" 2>&1 | tail -2 >> "$LOG"

  local speed reqs resps notes
  speed=$(echo "$raw" | sed -n 's/^Speed: \([0-9]*\) request\/sec.*/\1/p')
  reqs=$(echo "$raw" | sed -n 's/^Requests: \([0-9]*\)/\1/p')
  resps=$(echo "$raw" | sed -n 's/^Responses: \([0-9]*\)/\1/p')
  notes=""
  [ "$rc" -ne 0 ] && notes="client-rc=$rc"
  if echo "$raw" | grep -q 'Read error'; then
    notes="${notes}${notes:+;}read-errors=$(echo "$raw" | grep -c 'Read error')"
  fi
  # Any refused connection means the reported rate came from fewer clients than requested, so
  # the cell is not comparable even though a Speed line was printed.
  if echo "$raw" | grep -q 'Connect error'; then
    notes="${notes}${notes:+;}connect-errors=$(echo "$raw" | grep -c 'Connect error')"
  fi
  [ -z "$speed" ] && notes="${notes}${notes:+;}no-speed-line"
  # A nonzero delta on any physical core disqualifies the cell rather than merely qualifying it.
  case "$thr_d" in
    *[1-9]*) notes="${notes}${notes:+;}THROTTLED=$thr_d" ;;
  esac
  # A foreign container appearing mid-cell means this number was taken against unknown competing
  # load, which is disqualifying rather than noteworthy.
  [ -n "$foreign_after" ] && notes="${notes}${notes:+;}CONTENDED=${foreign_after% }"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PHASE" "$THREADS" "$round" "$label" "$len" "$conns" "$speed" "$reqs" "$resps" \
    "$thr_d" "${srvcli%%/*}" "${srvcli##*/}" "$(governor_now)" "$notes" >> "$OUT"
  log "  r$round $label len=$len c=$conns -> ${speed:-FAIL} req/s thr=$thr_d mhz=$srvcli ${notes:+($notes)}"

  docker rm -f "$SRV_NAME" >/dev/null 2>&1
  sleep 3
}

log "netty phase=$PHASE threads=$THREADS rounds=$ROUNDS warmup=${WARMUP}s measure=${DURATION}s"
log "lengths=[$LENGTHS] conns=[$CONNS]"
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
        run_cell epoll   epoll    "$round" "$len" "$conns"
        run_cell iouring io_uring "$round" "$len" "$conns"
      else
        run_cell iouring io_uring "$round" "$len" "$conns"
        run_cell epoll   epoll    "$round" "$len" "$conns"
      fi
    done
  done
  log "idle after round $round: $(vmstat 1 2 | tail -1 | awk '{print "id="$15}')"
done

log "done, results in $OUT"
