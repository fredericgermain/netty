#!/bin/bash
# Put a live, RAM-resident session into a state where a benchmark result means something, on
# whichever of the two machines booted it.
#
# Why a second script rather than the rig repo's bench-tuning.sh: that one configures one installed
# host, with one measured clock cap, and assumes its settings outlive the shell that set them. This
# one runs from a USB key on more than one machine, where the topology, the sustainable clock and
# even the presence of Dell's thermal control all differ, and where NOTHING survives a reboot.
#
#   bench-usb.sh check     verify without changing anything; exits nonzero if not ready
#   bench-usb.sh start     apply, then verify
#   bench-usb.sh stop      restore stock
#
# The replication protocol this serves is REPLICATION.md.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CMD="${1:-check}"
FAILED=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mBAD\033[0m  %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }

MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -s ' ' | sed 's/ *$//')

# The sustainable all-core clock, as a percentage of the part's maximum, PER MACHINE.
#
# This table is deliberately not a default. 62 was measured on the XPS 15 9500: it is the highest
# clock that chassis holds on all 8 threads without reaching its 100 C trip point, and it is a
# property of that chassis and that 45 W H-series part. Applying it unexamined to a 15 W U-series
# part in a 13-inch shell would produce a number that looks careful and is not. An unknown machine
# therefore stops the script rather than inheriting someone else's figure.
#
# To add a machine: run the rig repo's sweeps/coresweep3.sh on it, find the highest percentage with
# a zero throttle delta across all cores, and put it here with the date it was measured.
case "$MODEL" in
  "XPS 15 9500")  PERF_PCT=62  ; PCT_SRC="measured 2026-08-27, dell-xps-9500-bench-rig" ;;
  "XPS 13 9380")  PERF_PCT=""  ; PCT_SRC="NOT YET MEASURED -- run coresweep3.sh first" ;;
  *)              PERF_PCT=""  ; PCT_SRC="unknown machine" ;;
esac

# ---------------------------------------------------------------- the session itself
#
# A live session is only worth the trouble if it is actually the clean room it claims to be, so each
# of these is checked rather than assumed.
report_session() {
  echo "== session: $MODEL, $(uname -r), $(date -Is)"

  local rootfs
  rootfs=$(awk '$2 == "/" {print $3; exit}' /proc/mounts)
  case "$rootfs" in
    tmpfs|ramfs|overlay) ok "root is $rootfs (RAM-resident or overlay: state does not accumulate)" ;;
    *) warn "root is $rootfs, an installed system. Valid to benchmark, but it is NOT the same host as the live session, and the two must not be mixed in one comparison." ;;
  esac

  local memgb avail
  memgb=$(awk '/^MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)
  avail=$(awk '/^MemAvailable/ {printf "%.1f", $2 / 1048576}' /proc/meminfo)
  echo "   memory ${memgb} GB total, ${avail} GB available"
  # On a RAM-resident root the image store competes with the workload for the same memory, and
  # tmpfs pages cannot be evicted under pressure the way page cache can.
  if [ "$rootfs" = tmpfs ] || [ "$rootfs" = ramfs ]; then
    local droot
    droot=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "?")
    local dfs
    dfs=$(df --output=fstype "$droot" 2>/dev/null | tail -1)
    if [ "$dfs" = tmpfs ]; then
      warn "docker root $droot is tmpfs: every image layer is resident RAM and cannot be evicted. On a ${memgb} GB machine, size it deliberately or move it to a USB partition."
    else
      ok "docker root $droot is on $dfs, not competing with the workload for RAM"
    fi
  fi

  # Nothing here survives a reboot, so results have to land somewhere that is not this session.
  # ENVIRONMENT.md 7.3: every RECALLED tag on this branch exists because a number reached a document
  # without its raw record attached.
  if [ -n "${RESULTS_DIR:-}" ]; then
    local rfs
    rfs=$(df --output=fstype "$RESULTS_DIR" 2>/dev/null | tail -1)
    if [ -z "$rfs" ]; then bad "RESULTS_DIR=$RESULTS_DIR does not exist"
    elif [ "$rfs" = tmpfs ] || [ "$rfs" = ramfs ]; then
      bad "RESULTS_DIR=$RESULTS_DIR is $rfs: raw output would die with the session"
    else ok "results to $RESULTS_DIR on $rfs"
    fi
  else
    bad "RESULTS_DIR unset: set it to a USB partition or an sshfs/NFS path before measuring"
  fi
}

report_tuning() {
  echo "== tuning"
  if [ -z "$PERF_PCT" ]; then
    bad "no measured clock cap for '$MODEL' ($PCT_SRC)"
    echo "       Refusing to borrow another machine's figure. Derive it, then add it to this script."
  fi

  local mode
  if command -v smbios-thermal-ctl >/dev/null 2>&1; then
    mode=$(sudo -n smbios-thermal-ctl -g 2>/dev/null | grep -A1 'Current Thermal Modes' | tail -1 | tr -d '\t ')
    [ "$mode" = "Performance" ] && ok "dell thermal mode = $mode" || bad "dell thermal mode = ${mode:-unreadable}, wanted Performance"
  else
    # Measured on the 9500: Performance moves fan onset from 97 C to 90 C. Without the tool the fans
    # stay on the lazy stock curve, which is a real difference between the two machines' conditions.
    warn "smbios-thermal-ctl absent (libsmbios not installed, or the BIOS does not expose it). The stock fan curve leaves both fans at 0 RPM until ~97 C on Dell hardware; record that this run had no thermal-mode control."
  fi

  local govs
  govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ')
  [ "$(echo $govs)" = "performance" ] && ok "governor = performance on all cpus" || bad "governor = ${govs:-unreadable}"

  if [ -r /sys/devices/system/cpu/intel_pstate/min_perf_pct ]; then
    local minp maxp
    minp=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct)
    maxp=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)
    if [ -n "$PERF_PCT" ] && [ "$minp" = "$PERF_PCT" ] && [ "$maxp" = "$PERF_PCT" ]; then
      ok "clock pinned at min=max=${PERF_PCT}% ($PCT_SRC)"
    else
      bad "min_perf_pct=$minp max_perf_pct=$maxp, wanted both ${PERF_PCT:-<unmeasured>}"
    fi
  else
    bad "no intel_pstate on this machine; the clock cannot be pinned this way"
  fi

  local par kpt
  par=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null)
  kpt=$(sysctl -n kernel.kptr_restrict 2>/dev/null)
  [ "${par:-9}" -le 1 ] && ok "perf_event_paranoid = $par" || bad "perf_event_paranoid = $par, wanted <= 1"
  [ "${kpt:-9}" = "0" ] && ok "kptr_restrict = $kpt" || bad "kptr_restrict = $kpt, wanted 0"

  # SO_BACKLOG defaults to 200 in netty and the sweeps raise it to 8192. If somaxconn does not match,
  # the kernel truncates the accept queue silently and a 10k-connection ramp stalls rather than fails.
  local soma
  soma=$(sysctl -n net.core.somaxconn 2>/dev/null)
  [ "${soma:-0}" -ge 8192 ] && ok "somaxconn = $soma" || bad "somaxconn = $soma, wanted >= 8192 to match SO_BACKLOG"
}

report_topology() {
  echo "== topology"
  if . "$HERE/topology.sh" 2>/dev/null; then
    ok "$(topology_line | sed 's/^# //')"
  else
    bad "topology could not be derived; do not pin by hand without reading thread_siblings_list"
  fi
}

report_state() {
  echo "== observed state"
  local t
  t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
  echo "   package $(( ${t:-0} / 1000 )) C, load $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "   throttle counts: $(for c in ${THROTTLE_CORES:-0}; do printf '%s ' "$(cat /sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count 2>/dev/null || echo ?)"; done)"
  local foreign
  foreign=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -vcE '^(claudecodeui)$' || true)
  [ "${foreign:-0}" -eq 0 ] && ok "no foreign containers" ||
    bad "$foreign foreign container(s); a contended cell has been observed to INVERT a transport ordering"
}

apply_start() {
  [ -n "$PERF_PCT" ] || { echo "refusing to apply: no measured clock cap for '$MODEL'" >&2; exit 2; }
  command -v smbios-thermal-ctl >/dev/null 2>&1 &&
    sudo -n smbios-thermal-ctl --set-thermal-mode=performance >/dev/null 2>&1
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    sudo -n sh -c "echo performance > $c" 2>/dev/null
  done
  sudo -n sh -c "echo $PERF_PCT > /sys/devices/system/cpu/intel_pstate/max_perf_pct" 2>/dev/null
  sudo -n sh -c "echo $PERF_PCT > /sys/devices/system/cpu/intel_pstate/min_perf_pct" 2>/dev/null
  sudo -n sysctl -qw kernel.perf_event_paranoid=1 2>/dev/null
  sudo -n sysctl -qw kernel.kptr_restrict=0 2>/dev/null
  sudo -n sysctl -qw net.core.somaxconn=8192 2>/dev/null
}

apply_stop() {
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

case "$CMD" in
  start) apply_start; report_session; report_topology; report_tuning; report_state ;;
  stop)  apply_stop; echo "== restored: governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) min/max=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null)/$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null)"; exit 0 ;;
  check) report_session; report_topology; report_tuning; report_state ;;
  *) echo "usage: $0 start|stop|check" >&2; exit 2 ;;
esac

echo
[ "$FAILED" = 0 ] && echo "== READY" || echo "== NOT READY, do not trust results taken now"
exit $FAILED
