#!/bin/bash
# How many cores can this XPS 15 9500 hold at 100% without thermal throttling?
#
# Third attempt. The first measured the chassis together with Dell's "Balanced" fan curve, which
# leaves both fans at 0 RPM through 94 C and only starts them at 97 C, so it could not separate
# cooling policy from cooling capacity. The mode is now "Performance". The second attempt started
# each level on a machine still hot from the level before and reported 92 C for a SINGLE core, which
# is nonsense, so this one waits for a genuinely cool start before every level.
#
# The answer is the ceiling for any benchmark run on this host: above it, the clock moves during the
# measurement and cells stop being comparable.
set -u

MARK=CORESWEEP3_MARKER
BURN=45
COOL_TARGET=55     # C; every level starts from here so levels are comparable to each other
COOL_MAX=180       # seconds to wait for that before giving up and saying so

cleanup() {
  pkill -9 -f "$MARK" 2>/dev/null
  # Restore what bench-tuning.service sets, since this script deliberately deviates from it.
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/max_perf_pct' 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  echo "== restored to bench-tuning state: min=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct) max=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct), burners=$(pgrep -cf "$MARK" 2>/dev/null || echo 0)"
}
trap cleanup EXIT INT TERM

pkg()  { sensors 2>/dev/null | awk '/^Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}'; }
fan1() { sensors 2>/dev/null | awk '/^fan1:/ {print $2}'; }
fan2() { sensors 2>/dev/null | awk '/^fan2:/ {print $2}'; }
thr()  { local s=0 c; for c in 0 1 2 3; do s=$((s + $(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null || echo 0))); done; echo $s; }

cool_down() {
  local waited=0 t
  while [ $waited -lt $COOL_MAX ]; do
    t=$(pkg); t=${t%.*}
    [ "${t:-99}" -le $COOL_TARGET ] && { echo "$t"; return 0; }
    sleep 5; waited=$((waited + 5))
  done
  echo "${t:-?}"; return 1
}

echo "thermal mode : $(sudo -n smbios-thermal-ctl -g 2>/dev/null | grep -A1 'Current Thermal Modes' | tail -1 | tr -d '\t ')"
echo "ambient      : 24 C (user-supplied)"
echo "clock        : uncapped for this test, restored to 62% afterwards"
echo

# Uncapped, because the question is about cores at 100%. The CPU protects itself at its 100 C trip
# point, so the failure mode is throttling rather than damage.
sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

printf '%-6s %-9s %-9s %-9s %-7s %-7s %-10s %s\n' \
  "cores" "startC" "peakC" "meanMHz" "fan1" "fan2" "throttleD" "verdict"

# Physical cores 0-3 first, then their SMT siblings, so "4" is four real cores rather than two
# hyperthreaded pairs.
ORDER="0 1 2 3 4 5 6 7"

for n in 1 2 3 4 6 8; do
  start=$(cool_down) || echo "  (warning: did not reach ${COOL_TARGET}C within ${COOL_MAX}s, started at ${start}C)"
  before=$(thr)
  for c in $(echo $ORDER | cut -d' ' -f1-$n); do
    taskset -c "$c" sh -c 'while :; do :; done' "$MARK" &
  done

  # Track the PEAK rather than a single end-of-window sample: the interesting quantity is whether it
  # ever reached the trip point, not where it happened to be at one instant.
  peak=0
  for i in $(seq 1 $((BURN / 3))); do
    sleep 3
    t=$(pkg); t=${t%.*}
    [ "${t:-0}" -gt "$peak" ] && peak=$t
  done

  mhz=$(awk '{s+=$1; c++} END {printf "%d", s/c/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
  f1=$(fan1); f2=$(fan2)
  after=$(thr)
  pkill -9 -f "$MARK" 2>/dev/null
  d=$((after - before))

  printf '%-6s %-9s %-9s %-9s %-7s %-7s %-10s %s\n' \
    "$n" "${start}" "${peak}" "${mhz:-?}" "${f1:-?}" "${f2:-?}" "$d" \
    "$([ "$d" -gt 0 ] && echo 'THROTTLED' || echo 'clean')"
done
echo CORESWEEP3_DONE
