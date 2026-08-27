#!/usr/bin/env bash
# Q1. QUIC against TCP+TLS at equal payload and equal connection count.
#
# The comparison has to be against TCP+TLS and not against plaintext. QUIC always encrypts, so a
# plaintext TCP cell would be measuring AES rather than transport, and this branch already has that
# number under a different name.
#
# 500 connections, not the 10,000 every Part D cell used. A QUIC handshake is a full TLS 1.3
# exchange plus quiche's own connection setup, with no accept queue to absorb a burst, and at
# 10,000 the ramp would dominate a 10-second run rather than be reported next to it. 500 is also
# 500 UDP sockets on the client, one per connection, inside a 4-core cpuset. The TCP cell runs at
# the same 500 so the two ramps are the same size of question.
#
# Both cells interleaved inside every round, and which one leads alternates by round, so neither
# machine drift nor a first-cell warm-up effect can map onto the protocol axis.
#
# Usage: quic-vs-tcp.sh [rounds] [duration]

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

ROUNDS="${1:-5}"
DUR="${2:-10}"
CONNS="${CONNS:-500}"
THREADS=4
PAYLOADS="${PAYLOADS:-1024 8192 65536}"
# Overridable because the first Q1 run dropped 21,575 datagrams in the 64 KB QUIC cell at the 4 MB
# default, which disqualifies that cell: the kernel discarded the packets, quiche retransmitted, and
# the throughput figure was really the loss. The 64 KB row is re-run with a larger buffer and both
# runs are reported. TCP ignores this flag, so the two cells stay comparable.
UDP_RCVBUF="${UDP_RCVBUF:-}"

# Wait rather than refuse: run-all.sh launches these back to back on a shared host, and a sweep
# that exited because a neighbour happened to be mid-cell would simply be lost.
await_quiet || { echo "HOST NEVER WENT QUIET" >&2; exit 1; }
require_idle || exit 1

echo "# q1 quic-vs-tcp+tls  rounds=$ROUNDS duration=${DUR}s connections=$CONNS threads=$THREADS udpRcvbuf=${UDP_RCVBUF:-default4MB} payloads=$PAYLOADS"
echo "# image=$IMG"
host_header
printf 'round\tpayload\tcell\tconnPerSec\trampMs\treqPerSec\tp50us\tp99us\tp999us\terrors\tudpRcvbufErrDelta\tudpInErrDelta\t'"$ENV_HEADER"'\n'

cell() {   # cell <round> <payload> <quic|tcp>
  local round=$1 payload=$2 proto=$3
  local port srv before after
  await_quiet || { echo "# ABORT: host never went quiet" >&2; return 1; }
  port=$(free_port) || return 1

  local srv_args cli_args
  if [ "$proto" = quic ]; then
    local buf=""
    [ -n "$UDP_RCVBUF" ] && buf="--udp-rcvbuf=$UDP_RCVBUF"
    srv_args="--protocol=quic --transport=epoll --threads=$THREADS --quic-server-sockets=$THREADS --payload=$payload $buf"
    cli_args="--protocol=quic --transport=epoll --threads=$THREADS $buf"
  else
    srv_args="--transport=epoll --tls=openssl --threads=$THREADS --backlog=8192 --payload=$payload"
    cli_args="--transport=epoll --tls=openssl --threads=$THREADS"
  fi

  before=$(udp_counters)
  srv=$(start_server "$port" $srv_args) || {
    printf '%s\t%s\t%s\tSERVER-FAILED\n' "$round" "$payload" "$proto"; return 1; }

  run_client $((DUR + 240)) $cli_args --host=127.0.0.1 --port="$port" \
        --connections=$CONNS --duration=$DUR --payload=$payload
  after=$(udp_counters)
  stop_server "$srv" > /dev/null

  local ramp steady
  ramp=$(grep '^RAMP' "$CLIENT_OUT" | head -1)
  steady=$(grep '^STEADY' "$CLIENT_OUT" | head -1)
  if [ -z "$steady" ]; then
    printf '%s\t%s\t%s\tCLIENT-FAILED\n' "$round" "$payload" "$proto"
    tail -5 "$CLIENT_OUT" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$payload" "$proto" \
    "$(field "$ramp" connPerSec)" "$(field "$ramp" wallMs)" \
    "$(field "$steady" reqPerSec)" "$(field "$steady" p50us)" \
    "$(field "$steady" p99us)" "$(field "$steady" p999us)" "$(field "$steady" errors)" \
    "$(( $(udp_field "$after" RcvbufErrors) - $(udp_field "$before" RcvbufErrors) ))" \
    "$(( $(udp_field "$after" InErrors) - $(udp_field "$before" InErrors) ))" \
    "$(env_columns)"
}

for r in $(seq 1 "$ROUNDS"); do
  for p in $PAYLOADS; do
    if [ $((r % 2)) -eq 1 ]; then
      cell "$r" "$p" quic
      cell "$r" "$p" tcp
    else
      cell "$r" "$p" tcp
      cell "$r" "$p" quic
    fi
  done
done
echo Q1_DONE
