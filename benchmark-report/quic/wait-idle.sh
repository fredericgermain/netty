#!/usr/bin/env bash
# Blocks until the host is genuinely free, then exits 0. Exits 1 if it gives up.
#
# Needed because this host is shared and the neighbouring experiment's own supervisor has died at
# least once, so "it looked hung" is not evidence that it is finished: the run this was written
# against sat at 0% CPU for six minutes and then went back to saturating all eight logical cores.
# Only two consecutive clean polls count, for that reason.
#
# The load average on this host reads high and stale even when the CPU is free. vmstat is the
# authority, ps is the tie-break.
#
# Usage: wait-idle.sh [max-polls] [seconds-between]

set -u
MAX="${1:-80}"
GAP="${2:-30}"
clean=0

for i in $(seq 1 "$MAX"); do
  procs=$(ps -eo args | grep -E 'run-netty|echo_bench|lt\.jar' | grep -v grep | wc -l)
  idle=$(vmstat 1 3 | tail -1 | awk '{print $15}')
  if [ "$procs" -eq 0 ] && [ "$idle" -ge 95 ]; then
    clean=$((clean + 1))
    echo "poll $i: clean ($clean/2) idle=${idle}%"
    if [ "$clean" -ge 2 ]; then
      echo "THOR-IDLE"
      exit 0
    fi
  else
    clean=0
    echo "poll $i: procs=$procs idle=${idle}%"
  fi
  sleep "$GAP"
done
echo "GAVE-UP after $MAX polls"
exit 1
