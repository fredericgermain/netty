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
#   * This host is an Intel i5-10300H, a mobile part, with no pinned frequency. It throttles, and
#     its governor changed from powersave to performance partway through this work, so every sweep
#     records which one it ran under. `performance` with intel_pstate does NOT hold a uniform clock:
#     800 to 4131 MHz has been measured across the eight logical CPUs at idle. See the sampler.

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
CELL_SRV_MHZ=- ; CELL_CLI_MHZ=- ; CELL_FOREIGN=0 ; CELL_CONTENDED=no ; CELL_WAITED=no

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
# This host does not hold a clock. intel_pstate, 800 MHz to 4500 MHz, turbo on, so the governor may
# move across a 5.6x span inside one measured window. Switching it to `performance` does not fix
# that -- it raises the floor, it does not pin the clock -- so the frequency is measured rather than
# assumed, per cell and per side.
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

# Containers that are not this sweep's and not the unrelated always-present one. A single foreign
# container is enough to invalidate a cell on this host: a contended round has been observed to
# INVERT a transport ordering, not merely add noise, so this is a disqualifier and not a caveat.
foreign_containers() {
  docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -vE "^(claudecodeui|${SRV_NAME}|${CLI_NAME})\$" || true
}

# One line per tick: "<mhz per cpu, in cpu order> | <milliCelsius> | <foreign container count>"
#
# The per-CPU frequencies are kept separate rather than averaged, because the client and the server
# are pinned to different physical cores and the question of whether one side is running slower than
# the other is exactly the kind of thing that would look like a protocol difference.
#
# The foreign-container count is refreshed every fourth tick rather than every tick: `docker ps` is
# far dearer than reading two procfs files, and this sampler runs on the machine being measured.
sample_loop() {
  local i=0 foreign=0
  while :; do
    if [ $((i % 4)) -eq 0 ]; then
      foreign=$(foreign_containers | grep -c . || true)
    fi
    i=$((i + 1))
    printf '%s| %s | %s\n' \
      "$(awk '/^cpu MHz/ { printf "%.0f ", $4 }' /proc/cpuinfo)" \
      "$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)" \
      "$foreign"
    sleep 0.5
  done > "$1" 2>/dev/null
}

# Drops the first four ticks, which is the two seconds covering process start and the ramp, so the
# frequency reported is the frequency during the measured window rather than an average with idle.
#
# Server cores are 0,1,4,5 and client cores 2,3,6,7, which in /proc/cpuinfo order are fields
# 1,2,5,6 and 3,4,7,8. Reported separately so an asymmetry between the two sides is visible.
summarise_samples() {
  local s
  s=$(awk -F'|' 'NR > 4 {
        n = split($1, f, " ")
        for (i = 1; i <= n; i++) {
          v = f[i] + 0
          if (mn == "" || v < mn) mn = v
          if (mx == "" || v > mx) mx = v
          sum += v; cnt++
        }
        if (n >= 8) {
          srv += f[1] + f[2] + f[5] + f[6]; srvn += 4
          cli += f[3] + f[4] + f[7] + f[8]; clin += 4
        }
        if ($2 + 0 > tmax) tmax = $2 + 0
        if ($3 + 0 > fmax) fmax = $3 + 0
      }
      END {
        if (cnt == 0) { print "- - - - - - -"; exit }
        printf "%d %d %d %d %d %.1f %d\n", mn, mx, sum / cnt,
               (srvn ? srv / srvn : 0), (clin ? cli / clin : 0), tmax / 1000, fmax
      }' "$1")
  CELL_MHZ_MIN=$(echo "$s" | awk '{print $1}')
  CELL_MHZ_MAX=$(echo "$s" | awk '{print $2}')
  CELL_MHZ_MEAN=$(echo "$s" | awk '{print $3}')
  CELL_SRV_MHZ=$(echo "$s" | awk '{print $4}')
  CELL_CLI_MHZ=$(echo "$s" | awk '{print $5}')
  CELL_TEMP_MAX=$(echo "$s" | awk '{print $6}')
  CELL_FOREIGN=$(echo "$s" | awk '{print $7}')
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
  busy=$(ps -eo args | grep -E 'run-netty|run-matrix|echo_bench|lt\.jar' | grep -v grep || true)
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

# The per-cell gate, and the one that actually protects a result.
#
# A once-per-sweep check is not enough and this is not hypothetical: a sweep here passed its
# starting gate and then had a neighbour's experiment start on top of it three minutes before the
# end, and that whole sweep had to be discarded because a contended cell cannot be told from a clean
# one by looking at the number. So the gate runs before every cell, and requires BOTH that no
# foreign container exists AND that the CPU is at least 85% idle. run_client then re-checks
# throughout the measured window and tags the row.
require_quiet() {
  local foreign busy idle
  foreign=$(foreign_containers | tr '\n' ' ')
  if [ -n "${foreign// /}" ]; then
    echo "FOREIGN-CONTAINER: $foreign" >&2
    return 1
  fi
  # The process check is not redundant with the container check. A neighbouring sweep spends several
  # seconds between its cells with no container running at all, and a gate that looked only at
  # containers would pass in that gap and then start a cell straight into the neighbour's next one.
  #
  # It matches the neighbour's DRIVER scripts, which live for their whole run, and deliberately not
  # `lt.jar`: the neighbour and this harness use the same jar path, container processes are visible
  # in the host's ps, and `docker rm -f` returns before the process has finished dying. Matching it
  # would make every cell wait thirty seconds for its own predecessor and tag the whole sweep as
  # having waited.
  busy=$(ps -eo args | grep -E 'run-netty|run-matrix|echo_bench' | grep -v grep || true)
  if [ -n "$busy" ]; then
    echo "FOREIGN-PROCESS: $(echo "$busy" | head -1)" >&2
    return 1
  fi
  idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
  if [ "$idle" -lt 85 ]; then
    echo "NOT-QUIET: cpu idle ${idle}%" >&2
    return 1
  fi
  return 0
}

# Blocks until require_quiet passes, or gives up. Used between cells so a sweep pauses for a
# neighbour rather than recording through one.
await_quiet() {
  local i
  CELL_WAITED=no
  for i in $(seq 1 "${AWAIT_POLLS:-60}"); do
    if require_quiet 2>/dev/null; then
      return 0
    fi
    # Recorded per row. Interleaving protects a comparison by giving every cell in a round the same
    # machine state, and a pause of minutes between two cells of one round breaks that. Pausing is
    # still far better than measuring through a neighbour, but a round containing a pause should be
    # read with that in mind rather than assumed equivalent to one that ran straight through.
    CELL_WAITED=yes
    sleep 30
  done
  echo "AWAIT-QUIET-GAVE-UP" >&2
  return 1
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
  # Contended means a foreign container was seen at any point inside the measured window. On this
  # host that is a disqualifier: a contended round has been observed to reverse a transport
  # ordering, so such a row must be discarded rather than averaged in with a footnote.
  CELL_CONTENDED=$([ "${CELL_FOREIGN:-0}" -gt 0 ] && echo CONTENDED || echo no)
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

# The columns every sweep appends to a row, in a fixed order so the TSVs stay comparable.
env_columns() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$CELL_MHZ_MIN" "$CELL_MHZ_MAX" "$CELL_MHZ_MEAN" "$CELL_SRV_MHZ" "$CELL_CLI_MHZ" \
    "$CELL_TEMP_MAX" "$CELL_THROTTLE" "$CELL_CONTENDED" "$CELL_WAITED"
}

ENV_HEADER='mhzMin\tmhzMax\tmhzMean\tsrvMhz\tcliMhz\ttempMaxC\tthrottleDelta\tcontended\twaited'

# The line every sweep prints in its header, so a TSV records the machine state it was taken under
# rather than leaving it to be recalled. The governor changed from powersave to performance partway
# through this work and figures either side of that are not comparable.
host_header() {
  printf '# host governor=%s rmem_max=%s rmem_default=%s wmem_max=%s kernel=%s date=%s\n' \
    "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" \
    "$(cat /proc/sys/net/core/rmem_max)" "$(cat /proc/sys/net/core/rmem_default)" \
    "$(cat /proc/sys/net/core/wmem_max)" "$(uname -r)" "$(date -Is)"
}
