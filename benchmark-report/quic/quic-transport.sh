#!/usr/bin/env bash
# Q2. Which datagram transport QUIC performs best on.
#
# The TCP work on this branch found large differences between NIO, epoll and io_uring, so the same
# question has to be asked of the UDP socket underneath QUIC. It is not the same question, because
# a QUIC server has no accept: every connection arrives on one UDP socket and only SO_REUSEPORT can
# spread it across cores. Netty's NIO datagram channel cannot set SO_REUSEPORT, so NIO is capped at
# one socket, and a 4-socket epoll cell against a 1-socket NIO cell would be a thread-count
# comparison wearing a transport label.
#
# So two blocks, and they answer different questions:
#
#   1-socket  -- all three transports, one server socket each. The fair transport comparison.
#   4-socket  -- epoll and io_uring only. What the transport is worth once it can use the machine,
#                and the measure of what NIO gives up by not having SO_REUSEPORT.
#
# Usage: quic-transport.sh [rounds] [duration] [payload]

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

ROUNDS="${1:-5}"
DUR="${2:-10}"
PAYLOAD="${3:-1024}"
CONNS="${CONNS:-500}"
THREADS=4

# Wait rather than refuse: run-all.sh launches these back to back on a shared host, and a sweep
# that exited because a neighbour happened to be mid-cell would simply be lost.
await_quiet || { echo "HOST NEVER WENT QUIET" >&2; exit 1; }
require_idle || exit 1

echo "# q2 quic datagram transport sweep  rounds=$ROUNDS duration=${DUR}s connections=$CONNS payload=$PAYLOAD"
echo "# image=$IMG"
host_header
printf 'round\tcell\tsockets\tconnPerSec\trampMs\treqPerSec\tp50us\tp99us\tp999us\terrors\tudpRcvbufErrDelta\tudpInErrDelta\t'"$ENV_HEADER"'\n'

cell() {   # cell <round> <transport> <server-sockets>
  local round=$1 tr=$2 socks=$3
  local port srv before after
  await_quiet || { echo "# ABORT: host never went quiet" >&2; return 1; }
  port=$(free_port) || return 1

  before=$(udp_counters)
  srv=$(start_server "$port" --protocol=quic --transport="$tr" --threads=$THREADS \
        --quic-server-sockets="$socks" --payload="$PAYLOAD") || {
    printf '%s\t%s\t%s\tSERVER-FAILED\n' "$round" "$tr" "$socks"; return 1; }

  # The client transport tracks the server's, because the question is about the transport and not
  # about one particular pairing. Cross-transport pairs are a separate experiment (see D9).
  run_client $((DUR + 240)) --protocol=quic --transport="$tr" --threads=$THREADS \
        --host=127.0.0.1 --port="$port" --connections=$CONNS --duration=$DUR --payload="$PAYLOAD"
  after=$(udp_counters)
  stop_server "$srv" > /dev/null

  local ramp steady
  ramp=$(grep '^RAMP' "$CLIENT_OUT" | head -1)
  steady=$(grep '^STEADY' "$CLIENT_OUT" | head -1)
  if [ -z "$steady" ]; then
    printf '%s\t%s\t%s\tCLIENT-FAILED\n' "$round" "$tr" "$socks"
    tail -5 "$CLIENT_OUT" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$tr" "$socks" \
    "$(field "$ramp" connPerSec)" "$(field "$ramp" wallMs)" \
    "$(field "$steady" reqPerSec)" "$(field "$steady" p50us)" \
    "$(field "$steady" p99us)" "$(field "$steady" p999us)" "$(field "$steady" errors)" \
    "$(( $(udp_field "$after" RcvbufErrors) - $(udp_field "$before" RcvbufErrors) ))" \
    "$(( $(udp_field "$after" InErrors) - $(udp_field "$before" InErrors) ))" \
    "$(env_columns)"
}

for r in $(seq 1 "$ROUNDS"); do
  # Rotate which transport leads, so a first-cell effect cannot settle on one of them.
  case $((r % 3)) in
    1) order="nio epoll io_uring" ;;
    2) order="epoll io_uring nio" ;;
    *) order="io_uring nio epoll" ;;
  esac
  for t in $order; do
    cell "$r" "$t" 1
  done
  if [ $((r % 2)) -eq 1 ]; then
    cell "$r" epoll 4
    cell "$r" io_uring 4
  else
    cell "$r" io_uring 4
    cell "$r" epoll 4
  fi
done
echo Q2_DONE
