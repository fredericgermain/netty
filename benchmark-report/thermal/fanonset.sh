#!/bin/bash
# Did switching Dell's thermal mode to Performance actually change the fan curve?
#
# smbios-thermal-ctl reports success and reads back "Performance", but a setting that reads back is
# not the same as a setting that does something. The Balanced baseline is known precisely from an
# earlier run: both fans sat at 0 RPM through 86, 91 and 94 C and only started at 97 C, by which
# point the package was already at its 100 C trip point.
#
# So the test is the onset temperature, not the plateau. Start from a cool idle, ramp all 8 threads,
# and record the temperature at which each fan first moves. If the onset is materially below 97 C,
# the mode change is real and the earlier core sweep was measuring a lazy fan curve rather than the
# chassis.
#
# Waits for a genuinely cool start, because the previous attempt began on a machine still hot from
# the run before it and reported 92 C for a single core, which is nonsense.
set -u

MARK=FANONSET_MARKER
cleanup() {
  pkill -9 -f "$MARK" 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  sudo -n sh -c 'echo 62 > /sys/devices/system/cpu/intel_pstate/max_perf_pct' 2>/dev/null
  echo "== cleaned, min/max restored to 62"
}
trap cleanup EXIT INT TERM

pkg() { sensors 2>/dev/null | awk '/^Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}'; }
f1()  { sensors 2>/dev/null | awk '/^fan1:/ {print $2}'; }
f2()  { sensors 2>/dev/null | awk '/^fan2:/ {print $2}'; }

echo "mode: $(sudo -n smbios-thermal-ctl -g 2>/dev/null | grep -A1 'Current Thermal Modes' | tail -1 | tr -d '\t ')"

echo "== waiting for a cool start (<= 50 C), up to 3 minutes"
for i in $(seq 1 36); do
  t=$(pkg); t=${t%.*}
  [ "${t:-99}" -le 50 ] && break
  sleep 5
done
echo "   starting at $(pkg) C, fan1=$(f1) fan2=$(f2)"

sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

echo "== ramping 8 threads, sampling every 3 s"
for c in 0 1 2 3 4 5 6 7; do
  taskset -c "$c" sh -c 'while :; do :; done' "$MARK" &
done

onset1=""; onset2=""
for i in $(seq 1 25); do
  sleep 3
  t=$(pkg); a=$(f1); b=$(f2)
  [ -z "$onset1" ] && [ "${a:-0}" -gt 0 ] 2>/dev/null && onset1="$t"
  [ -z "$onset2" ] && [ "${b:-0}" -gt 0 ] 2>/dev/null && onset2="$t"
  printf '  t+%-4s pkg=%-6s fan1=%-6s fan2=%s\n' "$((i*3))s" "${t:-?}" "${a:-?}" "${b:-?}"
  # Once both fans are up and the package has plateaued there is nothing further to learn.
  [ -n "$onset1" ] && [ -n "$onset2" ] && [ "$i" -gt 12 ] && break
done

pkill -9 -f "$MARK" 2>/dev/null
echo
echo "== ONSET fan1 at ${onset1:-never} C, fan2 at ${onset2:-never} C"
echo "== Balanced baseline for comparison: both fans 0 RPM until 97 C"
echo FANONSET_DONE
