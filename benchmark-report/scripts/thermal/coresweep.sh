#!/bin/bash
# How many cores can this XPS 15 9500 hold at 100% without thermal throttling?
#
# The previous test showed the fans work (0 to ~3240/3510 RPM, and 100 C down to 63 C in 36 s once
# load stops) but that 8 threads at full clock still pins the package at 100 C and throttles
# continuously. That makes the useful question not "are the fans broken" but "what is the largest
# core count this chassis can actually sustain", because that number is the ceiling on any benchmark
# run here, and exceeding it silently corrupts results rather than failing.
#
# Runs uncapped (max_perf_pct=100) because the question is about 100% cores, not about the capped
# clock we benchmark under. Cores are allocated as distinct PHYSICAL cores first (0,1,2,3) and only
# then their SMT siblings (4,5,6,7), since two threads on one physical core generate less heat than
# two separate cores and mixing the two orders would confound the result.
set -u

BURN=45      # long enough to reach steady state; the previous test showed 100 C inside 30 s at 8x
COOL=25      # long enough to fall back under 70 C between levels

restore() {
  pkill -f fanburn 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/max_perf_pct' 2>/dev/null
  echo "== restored min=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct) max=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
}
trap restore EXIT INT TERM

throttle_sum() {
  local s=0
  for c in 0 1 2 3; do
    s=$((s + $(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null || echo 0)))
  done
  echo $s
}

sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

# Physical cores first, then siblings, so "4" means four real cores rather than two hyperthreaded.
ORDER="0 1 2 3 4 5 6 7"

printf '%-7s %-9s %-9s %-9s %-9s %s\n' "nCores" "pkgTempC" "meanMHz" "fan1" "fan2" "throttleDelta"
for n in 1 2 3 4 5 6 8; do
  cpus=$(echo $ORDER | cut -d' ' -f1-$n | tr ' ' ',')
  before=$(throttle_sum)
  for c in $(echo $ORDER | cut -d' ' -f1-$n); do
    ( exec -a fanburn taskset -c "$c" sh -c 'while :; do :; done' ) &
  done
  sleep $BURN
  temp=$(sensors 2>/dev/null | awk '/^Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}')
  mhz=$(awk '{s+=$1} END {printf "%d", s/NR/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
  f1=$(sensors 2>/dev/null | awk '/^fan1:/ {print $2}')
  f2=$(sensors 2>/dev/null | awk '/^fan2:/ {print $2}')
  after=$(throttle_sum)
  pkill -f fanburn 2>/dev/null
  printf '%-7s %-9s %-9s %-9s %-9s %s%s\n' "$n" "${temp:-?}" "${mhz:-?}" "${f1:-?}" "${f2:-?}" \
    "$((after - before))" "$([ $((after-before)) -gt 0 ] && echo '   <-- THROTTLED')"
  sleep $COOL
done
echo CORESWEEP_DONE
