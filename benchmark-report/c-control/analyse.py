#!/usr/bin/env python3
"""Turn the raw per-round TSVs into the median/spread tables quoted in README.md.

Spread is reported as the full observed min-max across rounds rather than a standard
deviation: with five rounds the extremes are what tell you whether two cells actually
separate, and an overlap between the two transports' ranges means the cell is not
established rather than a small effect.
"""

import sys
from collections import defaultdict
from statistics import median


def load(path):
    """Reads both TSV layouts. The netty runs carry an extra `threads` column, so the
    column names are taken from the header rather than assumed by position."""
    cells = defaultdict(dict)
    governors, throttles, mhz = set(), set(), {}
    with open(path) as fh:
        cols = fh.readline().rstrip("\n").split("\t")
        idx = {name: i for i, name in enumerate(cols)}
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < len(cols):
                continue
            get = lambda name: parts[idx[name]]
            rnd, transport = get("round"), get("transport")
            nbytes, conns = get("bytes"), get("conns")
            speed, notes = get("reqs_per_sec"), get("notes")
            if "governor" in idx and get("governor"):
                governors.add(get("governor"))
            if "throttle_d0123" in idx and get("throttle_d0123"):
                throttles.add(get("throttle_d0123"))
            if "cli_mhz" in idx and get("cli_mhz").isdigit():
                mhz.setdefault("cli", []).append(int(get("cli_mhz")))
            if "srv_mhz" in idx and get("srv_mhz").isdigit():
                mhz.setdefault("srv", []).append(int(get("srv_mhz")))
            if not speed:
                print(f"  !! failed run: {transport} {nbytes}B c={conns} r={rnd} {notes}",
                      file=sys.stderr)
                continue
            if notes:
                print(f"  !! noted run: {transport} {nbytes}B c={conns} r={rnd} {notes}",
                      file=sys.stderr)
            cells[(int(nbytes), int(conns))].setdefault(transport, []).append(int(speed))
    return cells, governors, throttles, mhz


def fmt(vals):
    return f"{median(vals):,} [{min(vals):,}-{max(vals):,}]"


def overlaps(a, b):
    return min(a) <= max(b) and min(b) <= max(a)


def main(path):
    cells, governors, throttles, mhz = load(path)
    print(f"\n### {path}\n")
    # Conditions belong next to the numbers: a sweep taken under a different governor, or one
    # that throttled, cannot be compared against another sweep just because the columns match.
    print(f"governor(s): {', '.join(sorted(governors)) or 'not recorded'}")
    nonzero = sorted(t for t in throttles if any(c.isdigit() and c != '0' for c in t))
    print(f"throttled cells: {len(nonzero)} of {sum(len(v) for c in cells.values() for v in c.values())}"
          f"{' -- deltas ' + ', '.join(nonzero) if nonzero else ''}")
    for side in ("srv", "cli"):
        if mhz.get(side):
            v = mhz[side]
            print(f"{side} clock MHz: median {int(median(v))} [{min(v)}-{max(v)}]")
    print()
    print("| bytes | conns | epoll req/s median [min-max] | io_uring req/s median [min-max] "
          "| io_uring / epoll | separated? |")
    print("|---|---|---|---|---|---|")
    for (nbytes, conns) in sorted(cells):
        got = cells[(nbytes, conns)]
        e = got.get("epoll")
        u = got.get("iouring")
        if not e or not u:
            print(f"| {nbytes} | {conns} | {e and fmt(e)} | {u and fmt(u)} | -- | incomplete |")
            continue
        ratio = median(u) / median(e)
        sep = "no (ranges overlap)" if overlaps(e, u) else "yes"
        print(f"| {nbytes} | {conns} | {fmt(e)} | {fmt(u)} | **{ratio:.2f}x** | {sep} |")
    print(f"\nrounds per cell: "
          f"{sorted({len(v) for c in cells.values() for v in c.values()})}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
