#!/usr/bin/env bash
# Every QUIC sweep, in priority order, in one detached run.
#
# One launch rather than five, because this host is shared and the neighbouring experiments come and
# go. Each sweep's per-cell `await_quiet` pauses for a neighbour instead of measuring through one, so
# a launch-and-leave run degrades into a slow run rather than into a corrupt one. A row whose cell
# had to wait is tagged `waited=yes`, and a row where a foreign container appeared inside the
# measured window is tagged `contended`, which disqualifies it.
#
# Priority order, so that a run cut short still answers the most important question:
#
#   q1   QUIC against TCP+TLS, three payloads              -- the headline
#   q1b  the 64 KB row again with a receive buffer that does not drop
#   q2   which datagram transport QUIC does best on
#   q4   what the receive buffer is worth, swept
#   q3   one stream per connection against five multiplexed
#
# Usage: run-all.sh [rounds] [duration]

DIR=$(cd "$(dirname "$0")" && pwd)
ROUNDS="${1:-5}"
DUR="${2:-10}"

cd "$DIR" || exit 1

echo "=== run-all starting $(date -Is), rounds=$ROUNDS duration=${DUR}s"

./quic-vs-tcp.sh    "$ROUNDS" "$DUR" > q1.tsv  2> q1.err
echo "=== q1 done $(date -Is)"

PAYLOADS=65536 UDP_RCVBUF=16777216 ./quic-vs-tcp.sh "$ROUNDS" "$DUR" > q1b.tsv 2> q1b.err
echo "=== q1b done $(date -Is)"

./quic-transport.sh "$ROUNDS" "$DUR" 1024 > q2.tsv 2> q2.err
echo "=== q2 done $(date -Is)"

./quic-rcvbuf.sh    "$ROUNDS" "$DUR" 65536 > q4.tsv 2> q4.err
echo "=== q4 done $(date -Is)"

./quic-streams.sh   "$ROUNDS" "$DUR" 1024 > q3.tsv 2> q3.err
echo "=== q3 done $(date -Is)"

echo "=== RUN_ALL_DONE $(date -Is)"
