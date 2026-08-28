#!/bin/bash
# Does the cooling on this XPS 15 9500 actually respond, or is it letting the CPU cook?
#
# Worth knowing because this host throttled to 100 C during a benchmark, and "the fans are not doing
# their job" and "a thin 15in chassis cannot dissipate sustained all-core turbo" are different
# problems with different fixes. The first is fixable with compressed air, the second is not fixable
# at all and means the benchmark ceiling has to be respected instead.
#
# Runs at FULL power deliberately (max_perf_pct 100), because the question is whether the cooling
# copes with the worst case, not with the capped case we benchmark under. The CPU protects itself at
# its 100 C trip point, so the risk is throttling rather than damage. Settings are restored at the
# end via a trap, including on interrupt.
set -u

RESTORE_MIN=62
RESTORE_MAX=62

restore() {
  sudo -n sh -c "echo $RESTORE_MIN > /sys/devices/system/cpu/intel_pstate/min_perf_pct" 2>/dev/null
  sudo -n sh -c "echo $RESTORE_MAX > /sys/devices/system/cpu/intel_pstate/max_perf_pct" 2>/dev/null
  pkill -f "fanburn" 2>/dev/null
  echo "== restored min=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct) max=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
}
trap restore EXIT INT TERM

sample() {
  local label=$1
  local f1 f2 pkg mhz
  f1=$(sensors 2>/dev/null | awk '/^fan1:/ {print $2}')
  f2=$(sensors 2>/dev/null | awk '/^fan2:/ {print $2}')
  pkg=$(sensors 2>/dev/null | awk '/^Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}')
  mhz=$(awk '{s+=$1} END {printf "%d", s/NR/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
  printf '%-9s fan1=%-6s fan2=%-6s pkgTemp=%-6s meanMHz=%-6s throttle=%s\n' \
    "$label" "${f1:-?}" "${f2:-?}" "${pkg:-?}" "${mhz:-?}" \
    "$(for c in 0 1 2 3; do printf '%s/' "$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null)"; done)"
}

echo "== uncapping to full power so the cooling is actually challenged"
sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

echo "== baseline, idle"
sample idle
sleep 3
sample idle

echo "== starting all-core burn on 8 logical CPUs"
for i in $(seq 1 8); do
  ( exec -a fanburn-$i sh -c 'while :; do :; done' ) &
done

for t in $(seq 1 20); do
  sleep 6
  sample "load+$((t*6))s"
done

echo "== stopping burn"
pkill -f fanburn 2>/dev/null
for t in $(seq 1 6); do
  sleep 6
  sample "cool+$((t*6))s"
done

echo FANTEST_DONE
