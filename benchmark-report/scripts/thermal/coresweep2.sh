#!/bin/bash
# How many cores hold 100% without thermal throttling, now that the fan profile is aggressive?
#
# The first attempt measured the chassis AND a conservative fan curve together and could not separate
# them: Dell's thermal mode was "Balanced", which leaves both fans at 0 RPM through 86, 91 and 94 C
# and only starts them at 97 C, by which point the package is already at its 100 C trip point. The
# mode is now "Performance", so this run measures what the hardware can actually sustain when the
# cooling is allowed to work.
#
# Uncapped (max_perf_pct=100) because the question is about cores at 100%, not about the capped clock
# used for benchmarking. The CPU protects itself at 100 C, so the risk is throttling, not damage.
#
# The burn processes carry a literal marker argument rather than a renamed argv[0]. The previous
# version used `exec -a fanburn taskset ... sh -c ...`, which renames taskset; taskset then execs sh
# and the name is lost, so pkill matched nothing and 31 loops survived the run. A trailing argument
# survives into the sh process and is greppable.
set -u

MARK=FANBURN_MARKER_9500
BURN=50
COOL=30

cleanup() {
  pkill -9 -f "$MARK" 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/max_perf_pct' 2>/dev/null
  echo "== cleaned: burners=$(pgrep -c -f "$MARK" 2>/dev/null || echo 0) min=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct) max=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
}
trap cleanup EXIT INT TERM

throttle_sum() {
  local s=0 c
  for c in 0 1 2 3; do
    s=$((s + $(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null || echo 0)))
  done
  echo $s
}

sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

echo "thermal mode: $(sudo -n smbios-thermal-ctl -g 2>/dev/null | grep -A1 'Current Thermal Modes' | tail -1 | tr -d '\t ')"
echo "ambient reference: 24 C (user-supplied)"
echo
printf '%-7s %-9s %-9s %-7s %-7s %-9s %s\n' "cores" "pkgTempC" "meanMHz" "fan1" "fan2" "throttleD" "verdict"

# Physical cores 0-3 first, then their SMT siblings 4-7, so "4" means four real cores rather than two
# hyperthreaded pairs. Mixing the two orders would confound heat with thread placement.
ORDER="0 1 2 3 4 5 6 7"

for n in 1 2 3 4 6 8; do
  before=$(throttle_sum)
  for c in $(echo $ORDER | cut -d' ' -f1-$n); do
    taskset -c "$c" sh -c 'while :; do :; done' "$MARK" &
  done
  sleep $BURN
  temp=$(sensors 2>/dev/null | awk '/^Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}')
  mhz=$(awk '{s+=$1; n++} END {printf "%d", s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
  f1=$(sensors 2>/dev/null | awk '/^fan1:/ {print $2}')
  f2=$(sensors 2>/dev/null | awk '/^fan2:/ {print $2}')
  after=$(throttle_sum)
  pkill -9 -f "$MARK" 2>/dev/null
  d=$((after - before))
  printf '%-7s %-9s %-9s %-7s %-7s %-9s %s\n' "$n" "${temp:-?}" "${mhz:-?}" "${f1:-?}" "${f2:-?}" "$d" \
    "$([ "$d" -gt 0 ] && echo 'THROTTLED' || echo 'clean')"
  sleep $COOL
done
echo CORESWEEP2_DONE
