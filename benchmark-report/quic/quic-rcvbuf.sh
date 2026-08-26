#!/usr/bin/env bash
# Q4. What the UDP receive buffer is worth, and what an undersized one looks like.
#
# This is the cell that says whether the rest of the QUIC numbers mean anything. An undersized UDP
# receive buffer is not an error: the kernel drops the datagram, quiche retransmits over the loss,
# and the operator reads it as "QUIC is slow". So the buffer is swept deliberately, with the
# kernel's own drop counter read around each cell, rather than set once and trusted.
#
# The interesting row is `default`: 212992 bytes is net.core.rmem_default on this host and is what a
# QUIC server that never calls setsockopt gets. If that row drops datagrams and the tuned rows do
# not, then every QUIC benchmark that inherited the default was measuring the drop.
#
# Run at the largest payload, because that is where the receive buffer is under most pressure: a
# 64 KB request is roughly 55 datagrams at a 1200-byte QUIC MTU, times the connection count.
#
# Usage: quic-rcvbuf.sh [rounds] [duration] [payload]

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

ROUNDS="${1:-5}"
DUR="${2:-10}"
PAYLOAD="${3:-65536}"
CONNS="${CONNS:-500}"
THREADS=4
# 212992 is net.core.rmem_default: what an untuned socket gets. The rest are deliberate choices
# under net.core.rmem_max, which is 50,000,000 here.
BUFS="212992 4194304 16777216"

require_idle || exit 1

echo "# q4 quic udp receive buffer sweep  rounds=$ROUNDS duration=${DUR}s connections=$CONNS payload=$PAYLOAD"
echo "# rmem_max=$(cat /proc/sys/net/core/rmem_max) rmem_default=$(cat /proc/sys/net/core/rmem_default)"
printf 'round\trcvbuf\tactual\tconnPerSec\treqPerSec\tp50us\tp99us\tp999us\terrors\tudpRcvbufErrDelta\tudpInErrDelta\tmhzMin\tmhzMax\tmhzMean\ttempMaxC\tthrottleDelta\n'

cell() {   # cell <round> <rcvbuf-bytes>
  local round=$1 buf=$2
  local port srv before after
  port=$(free_port) || return 1

  before=$(udp_counters)
  srv=$(start_server "$port" --protocol=quic --transport=epoll --threads=$THREADS \
        --quic-server-sockets=$THREADS --payload="$PAYLOAD" --udp-rcvbuf="$buf") || {
    printf '%s\t%s\tSERVER-FAILED\n' "$round" "$buf"; return 1; }
  # What the kernel actually applied, straight off the READY line rather than from the request.
  local actual
  actual=$(field "$(docker logs "$srv" 2>&1 | grep '^READY' | head -1)" udpRcvbufActual)

  run_client $((DUR + 240)) --protocol=quic --transport=epoll --threads=$THREADS \
        --host=127.0.0.1 --port="$port" --connections=$CONNS --duration=$DUR \
        --payload="$PAYLOAD" --udp-rcvbuf="$buf"
  after=$(udp_counters)
  stop_server "$srv" > /dev/null

  local ramp steady
  ramp=$(grep '^RAMP' "$CLIENT_OUT" | head -1)
  steady=$(grep '^STEADY' "$CLIENT_OUT" | head -1)
  if [ -z "$steady" ]; then
    printf '%s\t%s\tCLIENT-FAILED\n' "$round" "$buf"
    tail -5 "$CLIENT_OUT" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$buf" "$actual" \
    "$(field "$ramp" connPerSec)" \
    "$(field "$steady" reqPerSec)" "$(field "$steady" p50us)" \
    "$(field "$steady" p99us)" "$(field "$steady" p999us)" "$(field "$steady" errors)" \
    "$(( $(udp_field "$after" RcvbufErrors) - $(udp_field "$before" RcvbufErrors) ))" \
    "$(( $(udp_field "$after" InErrors) - $(udp_field "$before" InErrors) ))" \
    "$(env_columns)"
}

for r in $(seq 1 "$ROUNDS"); do
  # Rotate the leading buffer size so a first-cell effect cannot settle on one of them.
  case $((r % 3)) in
    1) order="212992 4194304 16777216" ;;
    2) order="4194304 16777216 212992" ;;
    *) order="16777216 212992 4194304" ;;
  esac
  for b in $order; do
    cell "$r" "$b"
  done
done
echo Q4_DONE
