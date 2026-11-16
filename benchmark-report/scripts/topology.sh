#!/bin/bash
# Derive the benchmark cpusets from the kernel's own topology, instead of assuming them.
#
# Why this exists: cpuset numbering lies. Every sweep on this branch for months pinned the server to
# `0-3` and the client to `4-7`, called them disjoint cores, and was wrong -- on a 4-core SMT part
# those two ranges ARE the four sibling pairs, so both sides shared physical cores. Measured both
# ways at 64 KB, the error moved the epoll/io_uring ratio from 50.9% to 43.7%, and it moved it
# against the transport under test.
#
# It matters a second time now: the same sweeps have to run on a second machine for replication, and
# a hardcoded cpuset that happens to be right on one host is a silent corruption on another.
#
# Source it and use the variables, or run it to print them:
#
#   . scripts/topology.sh            # exports SRV_CPUS CLI_CPUS SRV_FIELDS CLI_FIELDS THROTTLE_CORES
#   scripts/topology.sh              # prints the derivation for a log header
#
# Each side gets whole physical cores, half the cores each, server first. Note that correct pinning
# gives each side FEWER real cores than the wrong pinning appeared to, so absolute throughput drops
# even as the comparison becomes honest.

topology_derive() {
  local cpu sibs seen="" phys=() n half i c
  # Values set by the caller win. A machine this derivation cannot read correctly, or a deliberate
  # asymmetric pinning for a specific experiment, has to remain expressible -- but it is then the
  # caller who owns the claim that the cpusets are whole cores.
  local pre_srv="${SRV_CPUS:-}" pre_cli="${CLI_CPUS:-}"
  # Physical cores, in cpu order, identified by the first entry of their sibling list.
  for cpu in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//' | sort -n); do
    [ -r "/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list" ] || continue
    sibs=$(cat "/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list")
    # Normalise "0-4" and "0,4" to a space-separated list, then take the lowest as the core id.
    sibs=$(echo "$sibs" | tr ',-' '  ')
    local first=${sibs%% *}
    case " $seen " in *" $first "*) continue ;; esac
    seen="$seen $first"
    phys+=("$first")
  done

  TOPO_PHYS_CORES="${phys[*]}"
  n=${#phys[@]}
  if [ "$n" -lt 2 ]; then
    echo "topology: found $n physical core(s); need at least 2 to split server from client" >&2
    return 1
  fi
  # An odd core count would silently give one side more cores than the other, which is exactly the
  # kind of asymmetry this file exists to prevent. Refuse rather than round.
  if [ $((n % 2)) -ne 0 ]; then
    echo "topology: $n physical cores is odd; a 50/50 split is not possible, pin by hand" >&2
    return 1
  fi
  half=$((n / 2))

  local srv=() cli=() srvf=() clif=()
  for i in "${!phys[@]}"; do
    c=${phys[$i]}
    for s in $(cat "/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list" | tr ',-' '  '); do
      if [ "$i" -lt "$half" ]; then srv+=("$s"); else cli+=("$s"); fi
    done
  done
  # Sorted numerically so the cpuset string is stable across boots and comparable between machines.
  SRV_CPUS=$(printf '%s\n' "${srv[@]}" | sort -n | paste -sd,)
  CLI_CPUS=$(printf '%s\n' "${cli[@]}" | sort -n | paste -sd,)
  if [ -n "$pre_srv" ] || [ -n "$pre_cli" ]; then
    TOPO_OVERRIDDEN="derived srv=$SRV_CPUS cli=$CLI_CPUS, overridden by caller"
    SRV_CPUS="${pre_srv:-$SRV_CPUS}"
    CLI_CPUS="${pre_cli:-$CLI_CPUS}"
  fi

  # /proc/cpuinfo prints one "cpu MHz" line per logical cpu in cpu order, so cpu N is field N+1 for
  # the sampler that reads frequency per side.
  # Field positions follow whatever cpusets are actually in force, overridden or not, so the
  # per-side frequency columns never describe a different pinning from the one that ran.
  for s in $(echo "$SRV_CPUS" | tr ',' ' '); do srvf+=("$((s + 1))"); done
  for s in $(echo "$CLI_CPUS" | tr ',' ' '); do clif+=("$((s + 1))"); done
  SRV_FIELDS=$(printf '%s\n' "${srvf[@]}" | sort -n | paste -sd,)
  CLI_FIELDS=$(printf '%s\n' "${clif[@]}" | sort -n | paste -sd,)

  # Throttle counters are per physical core, so they are read from the first sibling of each.
  THROTTLE_CORES="${phys[*]}"
  export SRV_CPUS CLI_CPUS SRV_FIELDS CLI_FIELDS THROTTLE_CORES TOPO_PHYS_CORES
}

topology_line() {
  printf '# topology: %s physical cores (%s), server cpus %s, client cpus %s%s\n' \
    "$(echo "$TOPO_PHYS_CORES" | wc -w)" "$(echo "$TOPO_PHYS_CORES" | tr ' ' ',')" \
    "$SRV_CPUS" "$CLI_CPUS" "${TOPO_OVERRIDDEN:+ [$TOPO_OVERRIDDEN]}"
}

topology_derive || return 1 2>/dev/null || exit 1
# Run directly rather than sourced: print, so a run log can record what was derived.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  topology_line
  echo "SRV_CPUS=$SRV_CPUS"
  echo "CLI_CPUS=$CLI_CPUS"
  echo "SRV_FIELDS=$SRV_FIELDS"
  echo "CLI_FIELDS=$CLI_FIELDS"
  echo "THROTTLE_CORES=$THROTTLE_CORES"
fi
