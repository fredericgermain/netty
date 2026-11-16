#!/bin/bash
# The calibration workload ENVIRONMENT.md 7.1 has been asking for since it was written, and which
# nothing has ever implemented.
#
# The problem it solves: absolute throughput from two different machines, or from the same machine in
# two different years, are unrelated numbers. Expressed as a ratio to a fixed boring workload run
# alongside them, they become comparable. Without this, replicating a sweep on a second host tells
# you the two hosts differ but not whether the TRANSPORT behaved differently on them.
#
# Two anchors, deliberately:
#
#   compute   sha256 over a fixed 256 MiB buffer in RAM, on ONE core. CPU and memory only, no
#             kernel networking, no JVM. Moves with clock and memory speed.
#   network   one fixed cheap cell through the real harness: tcp/epoll, no TLS, 1 KB, 50
#             connections, one event loop thread. Moves with clock AND with the kernel's network
#             path.
#
# Having both is the point. If the network anchor moves between machines and the compute anchor does
# not, the difference is in the stack rather than in the silicon, and a transport comparison taken
# on the two hosts can still be read against each other. If both move by the same factor, it is
# clock and every cell scales with it.
#
# Usage:  JAR=/path/to/loadtest.jar scripts/calibrate.sh [label]
# Appends one TSV row to logs/calibration.tsv and prints it.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../quic/lib.sh"

LABEL="${1:-$(hostname)}"
OUT="${OUT:-$HERE/../logs/calibration.tsv}"
REPS=${REPS:-5}
BUF_MB=${BUF_MB:-256}

median() { sort -n | awk '{v[NR]=$1} END {print (NR % 2) ? v[(NR+1)/2] : int((v[NR/2] + v[NR/2+1]) / 2)}'; }

# ---------------------------------------------------------------- the compute anchor
#
# Runs inside the benchmark image so the anchor measures the machine and not whichever coreutils the
# host happens to ship. Pinned to a single server core, because a multi-core figure would fold in
# this chassis's thermal limit and that is the thing most likely to differ between two laptops.
#
# --shm-size is not optional: a container's /dev/shm defaults to 64 MiB, so a 256 MiB buffer written
# there silently fails and the anchor would measure a short file.
compute_anchor() {
  local core=${SRV_CPUS%%,*} out
  out=$(docker run --rm --cpuset-cpus="$core" --shm-size=$((BUF_MB * 2))m "$IMG" sh -c "
      dd if=/dev/zero of=/dev/shm/calib.bin bs=1M count=$BUF_MB status=none || exit 1
      [ \"\$(stat -c %s /dev/shm/calib.bin)\" = \"$((BUF_MB * 1024 * 1024))\" ] || { echo SHORT-BUFFER >&2; exit 1; }
      for i in \$(seq 1 $REPS); do
        s=\$(date +%s%N); sha256sum /dev/shm/calib.bin >/dev/null; e=\$(date +%s%N)
        echo \$(( (e - s) / 1000000 ))
      done") || { echo "compute anchor failed" >&2; return 1; }
  local ms
  ms=$(echo "$out" | median)
  [ "${ms:-0}" -gt 0 ] || { echo "compute anchor produced no timing" >&2; return 1; }
  # MiB/s, integer. Reported with the spread so a noisy anchor is visible rather than averaged away.
  COMPUTE_MIBS=$(( BUF_MB * 1000 / ms ))
  COMPUTE_SPREAD="$(echo "$out" | sort -n | head -1)-$(echo "$out" | sort -n | tail -1)ms"
}

# ---------------------------------------------------------------- the network anchor
#
# Deliberately small: 50 connections and one thread, which is below saturation on any machine this
# will run on. An anchor measured at saturation would move with whatever the machine's ceiling is,
# which is the very thing being calibrated away.
network_anchor() {
  local port cid line
  port=$(free_port) || return 1
  cid=$(start_server "$port" --transport=epoll --tls=none --threads=1 --backlog=8192) || return 1
  run_client 90 --transport=epoll --tls=none --host=127.0.0.1 --port="$port" \
      --connections=50 --duration=10 --payload=1024 --threads=1 >/dev/null 2>&1
  line=$(grep '^STEADY' "$CLIENT_OUT" | tail -1)
  stop_server "$cid" >/dev/null
  [ -n "$line" ] || { echo "network anchor produced no STEADY line" >&2; tail -5 "$CLIENT_OUT" >&2; return 1; }
  NET_RPS=$(field "$line" reqPerSec)
  # No fallback field name, on purpose. If reqPerSec is missing then the harness changed underneath
  # us, and an anchor that quietly reports some other metric is worse than one that fails.
  [ -n "$NET_RPS" ] || { echo "network anchor: no reqPerSec in the STEADY line" >&2; return 1; }
  # A cell with errors came from fewer clients than were asked for, so its rate is not the machines.
  local errs
  errs=$(field "$line" errors)
  [ "${errs:-0}" = 0 ] || { echo "network anchor: $errs errors, not a usable anchor" >&2; return 1; }
}

# ---------------------------------------------------------------- fingerprint
#
# ENVIRONMENT.md 7.2: every field here can invalidate a comparison, so the row carries them rather
# than relying on a run log that may not survive. Half the corrections on this branch came from one
# of these existing; the other half from one not existing yet.
fingerprint() {
  FP_CPU=$(awk -F: '/^model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)
  FP_KERNEL=$(uname -r)
  FP_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
  FP_PCT="$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || echo -)/$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || echo -)"
  FP_MEM_GB=$(awk '/^MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)
  FP_PHYS=$(echo "$TOPO_PHYS_CORES" | wc -w)
  FP_LOGICAL=$(nproc)
  # Whether / is RAM-resident, because a live-from-USB session and an installed system are not the
  # same host even on the same hardware.
  FP_ROOT=$(awk '$2 == "/" {print $3; exit}' /proc/mounts)
  FP_LIBC=$(docker run --rm "$IMG" sh -c 'ldd --version 2>&1 | head -1' 2>/dev/null | awk '{print $1}')
  FP_NETTY=$(unzip -p "$JAR" META-INF/MANIFEST.MF 2>/dev/null | awk -F': ' '/Implementation-Version/ {print $2}' | tr -d '\r')
}

main() {
  [ -f "$JAR" ] || { echo "JAR not found: $JAR" >&2; exit 2; }
  mkdir -p "$(dirname "$OUT")"
  require_idle || exit 1
  topology_line
  fingerprint
  compute_anchor || exit 1
  network_anchor || exit 1

  if [ ! -s "$OUT" ]; then
    printf 'ts\tlabel\tcomputeMiBs\tcomputeSpread\tnetRps\tcpu\tphys\tlogical\tmemGB\tkernel\tgovernor\tminMaxPct\trootFs\tlibc\tnettyVersion\tsrvCpus\tcliCpus\timage\t%b\n' "$ENV_HEADER" > "$OUT"
  fi
  local row
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(date -Is)" "$LABEL" "$COMPUTE_MIBS" "$COMPUTE_SPREAD" "$NET_RPS" \
    "$FP_CPU" "$FP_PHYS" "$FP_LOGICAL" "$FP_MEM_GB" "$FP_KERNEL" "$FP_GOV" "$FP_PCT" \
    "$FP_ROOT" "${FP_LIBC:-?}" "${FP_NETTY:-?}" "$SRV_CPUS" "$CLI_CPUS" "$IMG" "$(env_columns)")
  echo "$row" >> "$OUT"
  echo "$row"
  echo "# appended to $OUT"
  # A throttled or contended anchor is worse than no anchor, because every ratio taken against it
  # inherits the error silently.
  case "$CELL_THROTTLE" in *[1-9]*) echo "# WARNING throttled during the anchor ($CELL_THROTTLE): discard this row" ;; esac
  [ "$CELL_CONTENDED" = no ] || echo "# WARNING contended during the anchor: discard this row"
}

main "$@"
