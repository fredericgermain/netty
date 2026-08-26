#!/usr/bin/env bash
# Q3. One stream per connection against many streams multiplexed on one connection.
#
# Q1 uses one stream per connection because that is the honest analogue of one TCP connection.
# Multiplexing is the other thing QUIC is for, and it is a different cell rather than a better one:
# the same 500 request loops arrive over 500 connections or over 100, and everything else is held.
#
# What separates the two is per-connection state. 500 connections means 500 quiche connections, 500
# congestion controllers and 500 client UDP sockets; 100 connections with 5 streams each means a
# fifth of that, with five loops sharing one congestion window and one packet number space. If the
# multiplexed cell wins, the cost is per connection. If it loses, head-of-line blocking inside the
# connection is costing more than the state it saves.
#
# Usage: quic-streams.sh [rounds] [duration] [payload]

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

ROUNDS="${1:-5}"
DUR="${2:-10}"
PAYLOAD="${3:-1024}"
THREADS=4
LOOPS=500      # request loops, held equal across both cells

require_idle || exit 1

echo "# q3 quic streams-per-connection  rounds=$ROUNDS duration=${DUR}s loops=$LOOPS payload=$PAYLOAD"
printf 'round\tcell\tconns\tstreams\tconnPerSec\trampMs\treqPerSec\tp50us\tp99us\tp999us\terrors\tudpRcvbufErrDelta\tmhzMin\tmhzMax\tmhzMean\ttempMaxC\tthrottleDelta\n'

cell() {   # cell <round> <connections> <streams-per-conn>
  local round=$1 conns=$2 streams=$3
  local port srv before after
  port=$(free_port) || return 1

  before=$(udp_counters)
  srv=$(start_server "$port" --protocol=quic --transport=epoll --threads=$THREADS \
        --quic-server-sockets=$THREADS --payload="$PAYLOAD") || {
    printf '%s\t%sx%s\tSERVER-FAILED\n' "$round" "$conns" "$streams"; return 1; }

  run_client $((DUR + 240)) --protocol=quic --transport=epoll --threads=$THREADS \
        --host=127.0.0.1 --port="$port" --connections="$conns" --quic-streams="$streams" \
        --duration=$DUR --payload="$PAYLOAD"
  after=$(udp_counters)
  stop_server "$srv" > /dev/null

  local ramp steady
  ramp=$(grep '^RAMP' "$CLIENT_OUT" | head -1)
  steady=$(grep '^STEADY' "$CLIENT_OUT" | head -1)
  if [ -z "$steady" ]; then
    printf '%s\t%sx%s\tCLIENT-FAILED\n' "$round" "$conns" "$streams"
    tail -5 "$CLIENT_OUT" >&2
    return 1
  fi
  printf '%s\t%sx%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$conns" "$streams" "$conns" "$streams" \
    "$(field "$ramp" connPerSec)" "$(field "$ramp" wallMs)" \
    "$(field "$steady" reqPerSec)" "$(field "$steady" p50us)" \
    "$(field "$steady" p99us)" "$(field "$steady" p999us)" "$(field "$steady" errors)" \
    "$(( $(udp_field "$after" RcvbufErrors) - $(udp_field "$before" RcvbufErrors) ))" \
    "$(env_columns)"
}

for r in $(seq 1 "$ROUNDS"); do
  if [ $((r % 2)) -eq 1 ]; then
    cell "$r" "$LOOPS" 1
    cell "$r" $((LOOPS / 5)) 5
  else
    cell "$r" $((LOOPS / 5)) 5
    cell "$r" "$LOOPS" 1
  fi
done
echo Q3_DONE
