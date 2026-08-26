#!/usr/bin/env bash
# Shared plumbing for the QUIC sweeps. Sourced, never run.
#
# Everything in here exists because of a specific way a run on this host has already gone wrong:
#
#   * A `docker run` that fails leaves the previous container holding the name, and reading logs by
#     name then silently reads the OLD container's output. Every server here is started with
#     `docker run -d`, the returned id is kept, and the id registered under the name is compared
#     against it before anything is read.
#   * `timeout N docker run ...` kills the docker CLI, not the container. The container keeps
#     running, holding its name and its port, and that is how an orphan is born. Every client is
#     therefore force-removed before and after, on every path, and a trap covers the interrupts.
#   * Port 19999 is held by a long-standing orphan nobody owns. Ports are scanned, per cell, and
#     both the TCP and the UDP tables are checked because QUIC binds UDP and TCP binds TCP.
#   * This host is an Intel i5-10300H, a mobile part, with the powersave governor and no pinned
#     frequency. It throttles. See the sampler below.

set -u

IMG="${IMG:-eclipse-temurin:21-jdk}"          # glibc: the released QUIC native does not load on musl
JAR="${JAR:-$HOME/quic/loadtest.jar}"
SRV_CPUS=0,1,4,5                              # physical cores 0 and 1 with their SMT siblings
CLI_CPUS=2,3,6,7                              # physical cores 2 and 3 with theirs
SRV_NAME="${SRV_NAME:-q-srv}"
CLI_NAME="${CLI_NAME:-q-cli}"
CLIENT_OUT="${CLIENT_OUT:-/tmp/q-client-out.$$}"

# Set by run_client, read by the callers when they format a row.
CELL_MHZ_MIN=- ; CELL_MHZ_MAX=- ; CELL_MHZ_MEAN=- ; CELL_TEMP_MAX=- ; CELL_THROTTLE=-

cleanup() {
  docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
  docker rm -f "$CLI_NAME" >/dev/null 2>&1 || true
  rm -f "$CLIENT_OUT"
}
trap cleanup EXIT INT TERM

# A port free in both the UDP and the TCP tables. Scanned per cell rather than once per run: an
# orphaned container from an earlier cell would otherwise be inherited silently.
free_port() {
  local p
  for p in $(seq 19990 20050); do
    case "$p" in 19999|20044) continue ;; esac
    if ! ss -ulnH 2>/dev/null | grep -q ":$p " && ! ss -tlnH 2>/dev/null | grep -q ":$p "; then
      echo "$p"
      return 0
    fi
  done
  echo "no free port in 19990-20050" >&2
  return 1
}

# UDP counters straight out of /proc/net/snmp rather than netstat, so the field names come from the
# kernel and cannot be shifted by a locale or a net-tools version. RcvbufErrors is the one that
# matters: it counts datagrams the kernel dropped because the socket receive buffer was full, which
# QUIC then papers over with a retransmission and reports to the operator as slowness.
udp_counters() {
  awk '/^Udp:/ { if (!hdr) { for (i = 2; i <= NF; i++) name[i] = $i; hdr = 1 }
                 else { for (i = 2; i <= NF; i++) printf "%s=%s ", name[i], $i; print "" } }' \
      /proc/net/snmp
}

udp_field() {   # udp_field <counter-line> <name>
  echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print $2 }'
}

# ---------------------------------------------------------------- clock and heat
#
# This host does not hold a clock. intel_pstate, powersave governor, 800 MHz to 4500 MHz, turbo on,
# so the governor may move across a 5.6x span inside one measured window. It cannot be pinned
# without root here, so it is measured instead.
#
# The throttle DELTA is the part that decides whether a number survives. A cumulative count over ten
# days of uptime says only that the machine throttles sometimes; a nonzero delta across one cell
# says that cell was throttled and disqualifies it. The counters are per physical core, and on this
# host they are wildly asymmetric -- cores 2 and 3, which the client is pinned to, carry nearly all
# of it -- so all four are recorded separately rather than summed.
#
# There is also a mechanism by which this could bias the transport axis rather than merely add
# noise: io_uring parks threads in iowait, intel_pstate feeds iowait into its boost heuristic, and
# two transports can therefore run the same work at different clocks. Interleaving rounds does not
# average that away, so the frequency column is read per cell and not just per run.

throttle_counts() {   # "c0 c1 c2 c3"
  local c
  for c in 0 1 2 3; do
    cat "/sys/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_count" 2>/dev/null || echo 0
  done | tr '\n' ' '
}

throttle_delta() {   # throttle_delta "<before>" "<after>"  ->  d0/d1/d2/d3
  local b=($1) a=($2) i out=""
  for i in 0 1 2 3; do
    out="$out${out:+/}$(( ${a[$i]:-0} - ${b[$i]:-0} ))"
  done
  echo "$out"
}

sample_loop() {   # sample_loop <outfile>; one line per tick: "<mhz> <mhz> ... | <milliCelsius>"
  while :; do
    printf '%s| %s\n' \
      "$(awk '/^cpu MHz/ { printf "%.0f ", $4 }' /proc/cpuinfo)" \
      "$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)"
    sleep 0.5
  done > "$1" 2>/dev/null
}

# Drops the first four ticks, which is the two seconds covering process start and the ramp, so the
# frequency reported is the frequency during the measured window rather than an average with idle.
summarise_samples() {
  local s
  s=$(awk -F'|' 'NR > 4 {
        n = split($1, f, " ")
        for (i = 1; i <= n; i++) {
          if (mn == "" || f[i] + 0 < mn) mn = f[i] + 0
          if (mx == "" || f[i] + 0 > mx) mx = f[i] + 0
          sum += f[i] + 0; cnt++
        }
        t = $2 + 0
        if (t > tmax) tmax = t
      }
      END {
        if (cnt == 0) { print "- - - -"; exit }
        printf "%d %d %d %.1f\n", mn, mx, sum / cnt, tmax / 1000
      }' "$1")
  CELL_MHZ_MIN=$(echo "$s" | awk '{print $1}')
  CELL_MHZ_MAX=$(echo "$s" | awk '{print $2}')
  CELL_MHZ_MEAN=$(echo "$s" | awk '{print $3}')
  CELL_TEMP_MAX=$(echo "$s" | awk '{print $4}')
}

# ---------------------------------------------------------------- host state

# Refuses to continue unless the host is actually quiet. Called before every sweep, not just the
# first: a neighbour's run starting halfway through would otherwise land inside the interleaving.
#
# The load average on this host reads high and stale even when the CPU is free, so it is not
# consulted. vmstat's idle column is.
#
# ALLOW_NEIGHBOUR=1 downgrades the process check to a recorded warning, for one case only: somebody
# else's run that has hung, holding containers at zero CPU. Killing another agent's containers is
# not this script's business, and a container consuming no CPU does not perturb a measurement, but
# the fact belongs in the log rather than in nobody's memory. It does NOT relax the CPU check.
require_idle() {
  local busy idle
  busy=$(ps -eo args | grep -E 'run-netty|echo_bench|lt\.jar' | grep -v grep || true)
  if [ -n "$busy" ]; then
    if [ "${ALLOW_NEIGHBOUR:-0}" = 1 ]; then
      echo "# NEIGHBOUR-PRESENT (allowed explicitly): $(echo "$busy" | tr '\n' ';')"
      echo "# neighbour container cpu: $(docker stats --no-stream --format '{{.Name}}={{.CPUPerc}}' | tr '\n' ' ')"
    else
      echo "HOST-NOT-IDLE: $busy" >&2
      return 1
    fi
  fi
  idle=$(vmstat 1 3 | tail -1 | awk '{print $15}')
  if [ "$idle" -lt 90 ]; then
    echo "HOST-NOT-IDLE: cpu idle ${idle}%" >&2
    return 1
  fi
  echo "# host idle, cpu idle ${idle}%, throttleCounts(c0-c3)=$(throttle_counts)"
}

# ---------------------------------------------------------------- containers

# start_server <port> <extra args...>
# Echoes the container id it started, having proved that id is the one the name now resolves to.
start_server() {
  local port=$1; shift
  docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
  local cid
  cid=$(docker run -d --name "$SRV_NAME" --network=host --cpuset-cpus=$SRV_CPUS \
        --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
        -v "$JAR:/app/lt.jar:ro" "$IMG" \
        java -jar /app/lt.jar server --port="$port" "$@") || return 1
  local named
  named=$(docker ps -q --no-trunc --filter "name=^/${SRV_NAME}\$")
  if [ "$named" != "$cid" ]; then
    echo "CONTAINER-ID-MISMATCH started=$cid nameResolvesTo=$named" >&2
    docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
    return 1
  fi
  local i
  for i in $(seq 1 120); do
    if docker logs "$cid" 2>&1 | grep -q '^READY'; then
      echo "$cid"
      return 0
    fi
    if [ -z "$(docker ps -q --no-trunc --filter "id=$cid")" ]; then
      echo "SERVER-DIED cid=$cid" >&2
      docker logs "$cid" 2>&1 | tail -20 >&2
      docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
      return 1
    fi
    sleep 0.5
  done
  echo "SERVER-NO-READY cid=$cid" >&2
  docker logs "$cid" 2>&1 | tail -20 >&2
  docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
  return 1
}

# run_client <timeout-seconds> <args...>
#
# Output goes to $CLIENT_OUT rather than to stdout, deliberately: the caller would otherwise have to
# capture it in a command substitution, which is a subshell, and the frequency and throttle figures
# this function measures would be discarded with it.
run_client() {
  local secs=$1; shift
  docker rm -f "$CLI_NAME" >/dev/null 2>&1 || true
  local samples before after rc pid
  samples=$(mktemp)
  before=$(throttle_counts)
  sample_loop "$samples" &
  pid=$!
  timeout "$secs" docker run --name "$CLI_NAME" --network=host --cpuset-cpus=$CLI_CPUS \
      --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
      -v "$JAR:/app/lt.jar:ro" "$IMG" \
      java -jar /app/lt.jar client "$@" > "$CLIENT_OUT" 2>/dev/null
  rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  after=$(throttle_counts)
  docker rm -f "$CLI_NAME" >/dev/null 2>&1 || true
  summarise_samples "$samples"
  CELL_THROTTLE=$(throttle_delta "$before" "$after")
  rm -f "$samples"
  return $rc
}

stop_server() {
  local cid=$1
  docker logs "$cid" 2>&1 | grep '^SERVERCPU' | tail -1
  docker rm -f "$SRV_NAME" >/dev/null 2>&1 || true
}

field() {   # field <line> <key>   -- pulls key=value out of a harness output line
  echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print $2 }'
}

# The five columns every sweep appends to a row, in a fixed order so the TSVs stay comparable.
env_columns() {
  printf '%s\t%s\t%s\t%s\t%s' \
    "$CELL_MHZ_MIN" "$CELL_MHZ_MAX" "$CELL_MHZ_MEAN" "$CELL_TEMP_MAX" "$CELL_THROTTLE"
}
