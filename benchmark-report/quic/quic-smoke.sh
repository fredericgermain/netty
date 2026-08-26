#!/usr/bin/env bash
# Preflight for the QUIC sweeps: one cell, full output, nothing summarised.
#
# It exists to catch the failures that a summarising script would turn into a plausible-looking
# number: quiche not actually loaded, SO_REUSEPORT silently not applied, an SO_RCVBUF clamped by
# net.core.rmem_max to something far below the request, or a run whose throughput is really the
# kernel dropping datagrams. Run it, read the READY line, then run the sweeps.
#
# Usage: quic-smoke.sh [transport] [server-sockets] [payload] [connections] [duration]

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

TR="${1:-epoll}"
SOCKS="${2:-4}"
PAYLOAD="${3:-1024}"
CONNS="${4:-500}"
DUR="${5:-10}"

echo "== host"
uname -r
echo "rmem_max=$(cat /proc/sys/net/core/rmem_max) rmem_default=$(cat /proc/sys/net/core/rmem_default)"
echo "wmem_max=$(cat /proc/sys/net/core/wmem_max) wmem_default=$(cat /proc/sys/net/core/wmem_default)"
require_idle || echo "WARNING: host not idle, this is a smoke test so continuing"

port=$(free_port) || exit 1
echo "== port $port"
before=$(udp_counters)
echo "== udp before: $before"

srv=$(start_server "$port" --protocol=quic --transport="$TR" --threads=4 \
      --quic-server-sockets="$SOCKS" --payload="$PAYLOAD") || exit 1
echo "== server cid $srv"
docker logs "$srv" 2>&1 | grep '^READY'

echo "== reuseport check (expect $SOCKS sockets on :$port)"
ss -ulnp 2>/dev/null | grep ":$port " | wc -l

echo "== client"
run_client $((DUR + 240)) --protocol=quic --transport="$TR" --threads=4 \
    --host=127.0.0.1 --port="$port" --connections="$CONNS" --duration="$DUR" --payload="$PAYLOAD"
cat "$CLIENT_OUT"

echo "== clock during the measured window"
echo "mhzMin=$CELL_MHZ_MIN mhzMax=$CELL_MHZ_MAX mhzMean=$CELL_MHZ_MEAN tempMaxC=$CELL_TEMP_MAX throttleDelta(c0/c1/c2/c3)=$CELL_THROTTLE"

after=$(udp_counters)
echo "== udp after: $after"
echo "== RcvbufErrors delta: $(( $(udp_field "$after" RcvbufErrors) - $(udp_field "$before" RcvbufErrors) ))"
echo "== InErrors delta:     $(( $(udp_field "$after" InErrors) - $(udp_field "$before" InErrors) ))"

echo "== server tail"
docker logs "$srv" 2>&1 | grep '^SERVERCPU' | tail -2
stop_server "$srv" > /dev/null
echo SMOKE_DONE
