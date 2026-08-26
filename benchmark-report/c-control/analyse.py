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
    cells = defaultdict(dict)
    with open(path) as fh:
        header = fh.readline()
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 9:
                continue
            _phase, rnd, transport, nbytes, conns, speed, _r, _p, notes = parts[:9]
            if not speed:
                print(f"  !! failed run: {transport} {nbytes}B c={conns} r={rnd} {notes}",
                      file=sys.stderr)
                continue
            if notes:
                print(f"  !! noted run: {transport} {nbytes}B c={conns} r={rnd} {notes}",
                      file=sys.stderr)
            cells[(int(nbytes), int(conns))].setdefault(transport, []).append(int(speed))
    return cells


def fmt(vals):
    return f"{median(vals):,} [{min(vals):,}-{max(vals):,}]"


def overlaps(a, b):
    return min(a) <= max(b) and min(b) <= max(a)


def main(path):
    cells = load(path)
    print(f"\n### {path}\n")
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
