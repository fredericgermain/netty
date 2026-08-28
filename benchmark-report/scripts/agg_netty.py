"""Aggregate the recovered netty-driven-by-C-client sweeps.

This is the cross-check the whole io_uring investigation has been circling: netty's own server, but
driven by the C benchmark's client over a raw (unframed) protocol, so the Java load generator and the
length-prefixed framing are both taken out of the comparison. If netty's io_uring still loses here,
the deficit is in netty's transport. If it does not, the earlier numbers were measuring something
else.

Medians with the full round spread, because two claims on this branch were retracted for resting on
single runs.
"""
import os
import statistics
from collections import defaultdict

ROOT = "/Users/frederic.germain/workspaces/fred/netty-alpine/netty/.claude/worktrees/tls-matrix"
LOGS = os.path.join(ROOT, "benchmark-report/c-control/logs")

for name in ("results-netty-t4.tsv", "results-netty-t1.tsv", "results-big-perf.tsv"):
    path = os.path.join(LOGS, name)
    if not os.path.exists(path):
        continue
    rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip()]
    head, body = rows[0], rows[1:]
    idx = {c: i for i, c in enumerate(head)}

    def col(r, key, default=""):
        i = idx.get(key)
        return r[i] if i is not None and i < len(r) else default

    cells = defaultdict(list)
    throttled = 0
    for r in body:
        try:
            rps = int(col(r, "reqs_per_sec"))
        except ValueError:
            continue
        if col(r, "throttle_d0123", "0/0/0/0").strip() not in ("0/0/0/0", ""):
            throttled += 1
        cells[(col(r, "bytes"), col(r, "conns"), col(r, "transport"))].append(rps)

    print("######## %s   (%d rows, %d throttled)" % (name, len(body), throttled))
    seen = sorted({(int(b), int(c)) for b, c, _ in cells}, key=lambda x: (x[0], x[1]))
    print("  %-8s %-6s %-26s %-26s %s" % ("bytes", "conns", "epoll", "io_uring", "ratio"))
    for b, c in seen:
        ep = cells.get((str(b), str(c), "epoll"), [])
        ur = cells.get((str(b), str(c), "iouring"), []) or cells.get((str(b), str(c), "io_uring"), [])
        if not ep or not ur:
            continue
        mep, mur = statistics.median(ep), statistics.median(ur)
        # Overlapping ranges mean the cell is not established, so flag it rather than quote a ratio.
        overlap = not (max(ep) < min(ur) or max(ur) < min(ep))
        print("  %-8d %-6d %-26s %-26s %.2fx%s" % (
            b, c,
            "%d [%d-%d]" % (mep, min(ep), max(ep)),
            "%d [%d-%d]" % (mur, min(ur), max(ur)),
            mur / mep,
            "  OVERLAP, not established" if overlap else ""))
    print()
