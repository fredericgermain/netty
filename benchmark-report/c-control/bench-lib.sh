# Shared instrumentation for the C and netty runners.
#
# Everything here exists because thor is a mobile part (i5-10300H) whose clock policy and thermal
# behaviour are not constant across a session. Two sweeps taken hours apart are only comparable if
# each one records the conditions it ran under, so every cell carries its own governor, its own
# per-core throttle delta and its own observed clock.

SRV_PHYS_CORES="0 1 2 3"   # thermal_throttle counters exist per physical core only

governor_now() {
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown
}

# Cumulative counts prove only that the host throttles sometimes. The delta across one cell is what
# says whether THAT number was taken while throttled, which is the difference between a caveat and
# a disqualified measurement.
throttle_snapshot() {
  local c out=""
  for c in $SRV_PHYS_CORES; do
    out="$out$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null || echo -1) "
  done
  echo "${out% }"
}

throttle_delta() {
  local before="$1" after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN {
    nb = split(b, B, " "); na = split(a, A, " ");
    if (nb != na) { print "NA"; exit }
    s = "";
    for (i = 1; i <= nb; i++) s = s (A[i] - B[i]) (i < nb ? "/" : "");
    print s
  }'
}

# Sampled during the measured window rather than before it: the clock at the moment the run starts
# says nothing about the clock it settled to under load.
freq_sampler_start() {
  local outfile="$1" interval="${2:-2}"
  (
    while :; do
      local c line=""
      for c in 0 1 2 3 4 5 6 7; do
        line="$line$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) "
      done
      echo "$line"
      sleep "$interval"
    done
  ) > "$outfile" 2>/dev/null &
  echo $!
}

freq_sampler_stop() {
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

# Mean MHz over the sampled window, split by which side of the machine the cores belong to.
# Server runs on logical 0,1,4,5 and client on 2,3,6,7, which are fields 1,2,5,6 and 3,4,7,8.
freq_summary() {
  local f="$1"
  [ -s "$f" ] || { echo "NA/NA"; return; }
  awk '{ s += ($1+$2+$5+$6)/4; c += ($3+$4+$7+$8)/4; n++ }
       END { if (n) printf "%d/%d", s/n/1000, c/n/1000; else printf "NA/NA" }' "$f"
}

# thor is shared with other sessions. A foreign benchmark running concurrently does not merely add
# noise, it inverts cells: one contended round produced epoll 74k against io_uring 153k in a cell
# that reads 192k against 210k on a quiet host. Contention has to gate the measurement, not caveat
# it. OURS is the set of container name prefixes this experiment is allowed to see.
OURS_RE='^(cctl-|nctl-|claudecodeui$)'

foreign_containers() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Ev "$OURS_RE" | tr '\n' ' '
}

host_idle_pct() {
  vmstat 1 2 2>/dev/null | tail -1 | awk '{print $15}'
}

# Blocks until the host is quiet, rather than measuring through contention and discovering it
# afterwards. Returns non-zero if it gives up, so the caller can refuse to produce numbers at all.
wait_for_quiet() {
  local min_idle="${1:-85}" max_wait="${2:-3600}" waited=0 idle foreign
  while :; do
    foreign=$(foreign_containers)
    idle=$(host_idle_pct)
    if [ -z "$foreign" ] && [ "${idle:-0}" -ge "$min_idle" ]; then
      return 0
    fi
    if [ "$waited" -ge "$max_wait" ]; then
      echo "gave up waiting for a quiet host after ${waited}s (idle=${idle}% foreign=[${foreign:-none}])" >&2
      return 1
    fi
    sleep 30
    waited=$((waited + 30))
  done
}

# Reading container logs by NAME after a start that silently failed returns the PREVIOUS
# container's output, which is how a stale epoll server once got measured under an io_uring label.
# Every start therefore keeps the id docker returned and asserts the running container is that one.
assert_container_is() {
  local cid="$1" name="$2"
  local actual
  actual=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null)
  case "$actual" in
    "$cid"*) return 0 ;;
    *) return 1 ;;
  esac
}
