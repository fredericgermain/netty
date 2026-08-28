#!/bin/bash
# Put this host into, or take it out of, a state where a benchmark result means something.
#
#   bench-tuning.sh start     apply the benchmark settings
#   bench-tuning.sh stop      restore normal laptop behaviour
#   bench-tuning.sh check     verify without changing anything; exits nonzero if not ready
#
# Every setting here is volatile: the governor, both intel_pstate percentage limits and the two perf
# sysctls all reset on reboot. This host rebooted mid-investigation once and silently reverted all of
# them, and the settings had until now only ever been applied by hand from a conversation, which is
# how that went unnoticed. `stop` exists because these are bad settings for a laptop to sit in: the
# clock is pinned so it never idles down, and the fans engage far earlier than normal.
#
# Host this was written for: Dell XPS 15 9500, Intel i5-10300H, 4 physical cores and 8 threads.
set -u

CMD="${1:-check}"

# 62% of the 4.5 GHz maximum, landing near 2.8 GHz. Chosen by measurement:
#
#   powersave    dynamic across 800-4500 MHz. A 36% throughput swing between runs of the same cell.
#   performance  requests the maximum, reaches 100 C in 30 seconds on this chassis and then throttles
#                continuously, up to 533 throttle events in a single measured cell.
#   62% capped   2593 MHz mean, 62 C, zero throttle events, same throughput as powersave.
#
# min is set equal to max deliberately. Capping only the maximum leaves intel_pstate free to scale
# BELOW it, which is not a pinned clock: a run taken that way spanned 65767-101292 req/s, a 54%
# spread, while the recorded per-side frequency moved only 2528-2752 MHz.
PERF_PCT=62

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mBAD\033[0m  %s\n' "$1"; FAILED=1; }
FAILED=0

apply_start() {
  # Dell's default "Balanced" profile leaves both fans at 0 RPM through 86, 91 and 94 C and only
  # starts them at 97 C, by which point the package is at its 100 C trip point. Under "Performance"
  # they are at ~2800/3100 RPM by 90 C. Peak speed is unchanged at roughly 3240/3510 against a rated
  # 4800, so this changes when the cooling engages, not how hard it can work.
  command -v smbios-thermal-ctl >/dev/null 2>&1 &&
    sudo -n smbios-thermal-ctl --set-thermal-mode=performance >/dev/null 2>&1

  # intel_pstate's names mislead: its "powersave" governor is the DYNAMIC one, not a low-power mode.
  # "performance" plus an equal min and max is what actually pins the frequency.
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    sudo -n sh -c "echo performance > $c" 2>/dev/null
  done
  sudo -n sh -c "echo $PERF_PCT > /sys/devices/system/cpu/intel_pstate/max_perf_pct" 2>/dev/null
  sudo -n sh -c "echo $PERF_PCT > /sys/devices/system/cpu/intel_pstate/min_perf_pct" 2>/dev/null

  # Not needed to run a benchmark, but needed to explain one. Without these, kernel frames do not
  # resolve and a profiler has to be handed container capabilities instead.
  sudo -n sysctl -qw kernel.perf_event_paranoid=1 2>/dev/null
  sudo -n sysctl -qw kernel.kptr_restrict=0 2>/dev/null
}

apply_stop() {
  # Back to stock. min_perf_pct 17 is this machine's own floor, not an arbitrary choice.
  command -v smbios-thermal-ctl >/dev/null 2>&1 &&
    sudo -n smbios-thermal-ctl --set-thermal-mode=balanced >/dev/null 2>&1
  sudo -n sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct' 2>/dev/null
  sudo -n sh -c 'echo 17 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    sudo -n sh -c "echo powersave > $c" 2>/dev/null
  done
  sudo -n sysctl -qw kernel.perf_event_paranoid=4 2>/dev/null
  sudo -n sysctl -qw kernel.kptr_restrict=1 2>/dev/null
}

report() {
  echo "== benchmark environment, $(hostname), $(date -Is)"
  mode=$(sudo -n smbios-thermal-ctl -g 2>/dev/null | grep -A1 'Current Thermal Modes' | tail -1 | tr -d '\t ')
  [ "$mode" = "Performance" ] && ok "dell thermal mode = $mode" || bad "dell thermal mode = ${mode:-unknown}, wanted Performance"

  govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ')
  [ "$(echo $govs)" = "performance" ] && ok "governor = performance on all cpus" || bad "governor = $govs"

  minp=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null)
  maxp=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null)
  { [ "$minp" = "$PERF_PCT" ] && [ "$maxp" = "$PERF_PCT" ]; } &&
    ok "clock pinned at min=max=$PERF_PCT%" || bad "min_perf_pct=$minp max_perf_pct=$maxp, wanted both $PERF_PCT"

  par=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null)
  kpt=$(sysctl -n kernel.kptr_restrict 2>/dev/null)
  [ "${par:-9}" -le 1 ] && ok "perf_event_paranoid = $par" || bad "perf_event_paranoid = $par, wanted <= 1"
  [ "${kpt:-9}" = "0" ] && ok "kptr_restrict = $kpt" || bad "kptr_restrict = $kpt, wanted 0"

  # State no setting can fix, reported so a sweep can refuse to start rather than measure through it.
  echo "== observed state"
  echo "   package $(sensors 2>/dev/null | awk '/^Package id 0:/ {print $4}'), fans $(sensors 2>/dev/null | awk '/^fan1:/ {print $2}')/$(sensors 2>/dev/null | awk '/^fan2:/ {print $2}') RPM"
  echo "   throttle counts c0-c3: $(for c in 0 1 2 3; do printf '%s ' "$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null)"; done)"
  echo "   load $(cut -d' ' -f1-3 /proc/loadavg)"
  foreign=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -vc '^claudecodeui$' || true)
  [ "${foreign:-0}" -eq 0 ] && ok "no foreign containers" ||
    bad "$foreign foreign container(s); a contended cell has been observed to INVERT a transport ordering here"
}

case "$CMD" in
  start) apply_start; report; echo; [ "$FAILED" = 0 ] && echo "== READY" || echo "== NOT READY, do not trust results taken now" ;;
  stop)  apply_stop;  echo "== restored to stock: governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) min=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct) max=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"; FAILED=0 ;;
  check) report; echo; [ "$FAILED" = 0 ] && echo "== READY" || echo "== NOT READY, do not trust results taken now" ;;
  *)     echo "usage: $0 start|stop|check" >&2; exit 2 ;;
esac
exit $FAILED
