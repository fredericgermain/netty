#!/usr/bin/env bash
# Medians and per-round spreads out of a sweep's TSV.
#
# The spread is not decoration. Two claims on this branch were retracted because a difference was
# read off medians whose round spreads overlapped, so this prints min and max next to every median
# and marks any pair of cells in the same group whose ranges intersect as OVERLAP. A cell marked
# OVERLAP is "not established", not "a small effect".
#
# Usage: summarise.sh <tsv> <group-column> <cell-column> <value-column>
#        summarise.sh q1.tsv 2 3 6      # group by payload, cell by protocol, value reqPerSec

set -u
FILE=$1
GROUP=$2
CELL=$3
VALUE=$4

awk -v g="$GROUP" -v c="$CELL" -v v="$VALUE" -F'\t' '
  /^#/ || /^round/ || NF < 3 { next }
  $v ~ /^[0-9.]+$/ {
    key = $g "|" $c
    n[key]++
    vals[key, n[key]] = $v + 0
    if (!(key in lo) || $v + 0 < lo[key]) lo[key] = $v + 0
    if (!(key in hi) || $v + 0 > hi[key]) hi[key] = $v + 0
  }
  END {
    for (key in n) {
      # Insertion sort: a handful of rounds, so nothing cleverer is warranted.
      for (i = 2; i <= n[key]; i++) {
        x = vals[key, i]
        for (j = i - 1; j >= 1 && vals[key, j] > x; j--) vals[key, j + 1] = vals[key, j]
        vals[key, j + 1] = x
      }
      m = int((n[key] + 1) / 2)
      med[key] = (n[key] % 2) ? vals[key, m] : (vals[key, m] + vals[key, m + 1]) / 2
    }
    printf "%-12s %-12s %5s %12s %12s %12s %8s\n", "group", "cell", "n", "median", "min", "max", "spread%"
    for (key in n) {
      split(key, p, "|")
      sp = (lo[key] > 0) ? 100 * (hi[key] - lo[key]) / lo[key] : 0
      printf "%-12s %-12s %5d %12.0f %12.0f %12.0f %7.1f%%\n", p[1], p[2], n[key], med[key], lo[key], hi[key], sp
    }
    print ""
    # Every pair inside a group, so an overlap cannot be missed by only checking neighbours.
    for (k1 in n) {
      for (k2 in n) {
        split(k1, a, "|"); split(k2, b, "|")
        if (a[1] != b[1] || a[2] >= b[2]) continue
        overlap = (lo[k1] <= hi[k2] && lo[k2] <= hi[k1]) ? "OVERLAP:not-established" : "separated"
        ratio = (med[k2] > 0) ? med[k1] / med[k2] : 0
        printf "%-12s %-12s vs %-12s ratio=%.2fx  %s\n", a[1], a[2], b[2], ratio, overlap
      }
    }
  }
' "$FILE"
