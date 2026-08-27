"""Aggregate the QUIC vs TCP+TLS sweep, disqualifying cells rather than averaging over them.

Two failure modes have to be checked before any ratio is quoted, and both are present in this data:
UDP receive-buffer overflow (QUIC hides loss as retransmission, so it presents as "slow" rather than
as an error) and thermal throttling (nonzero deltas appeared for the first time on this branch once
the performance governor was set, because the CPU now runs hotter).
"""
import os
import statistics
from collections import defaultdict

ROOT = "/Users/frederic.germain/workspaces/fred/netty-alpine/netty/.claude/worktrees/tls-matrix"
path = os.path.join(ROOT, "benchmark-report/quic/logs/q1-capped.tsv")

rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip() and not l.startswith("#")]
head, body = rows[0], [r for r in rows[1:] if len(r) == len(rows[0])]
idx = {c: i for i, c in enumerate(head)}
print("columns:", " ".join(head))
print()


def get(r, key, default=""):
    i = idx.get(key)
    return r[i] if i is not None and i < len(r) else default


cells = defaultdict(list)
for r in body:
    try:
        rps = float(get(r, "reqPerSec"))
    except ValueError:
        continue
    # A cell is disqualified if the kernel dropped datagrams or if a core throttled during it.
    # Neither is recoverable by averaging: loss makes QUIC retransmit, and throttling changes the
    # clock the two sides ran at.
    try:
        drops = int(get(r, "udpRcvbufErrDelta", "0") or 0)
    except ValueError:
        drops = 0
    thr = get(r, "throttleDelta", "0/0/0/0")
    throttled = any(x.strip() not in ("", "0") for x in thr.split("/"))
    cells[(int(get(r, "payload")), get(r, "cell"))].append((rps, drops, throttled,
                                                            get(r, "connPerSec"), thr))

print("%-8s %-6s %-24s %-10s %-10s %s" % ("payload", "proto", "reqPerSec median [range]",
                                          "udpDrops", "throttled", "connPerSec median"))
for payload in sorted({p for p, _ in cells}):
    for proto in ("quic", "tcp"):
        v = cells.get((payload, proto))
        if not v:
            continue
        rps = [x[0] for x in v]
        drops = sum(x[1] for x in v)
        nthr = sum(1 for x in v if x[2])
        conns = [float(x[3]) for x in v if x[3].replace(".", "").isdigit()]
        print("%-8d %-6s %-24s %-10s %-10s %s" % (
            payload, proto,
            "%d [%d-%d]" % (statistics.median(rps), min(rps), max(rps)),
            drops if drops else "-",
            ("%d/%d rounds" % (nthr, len(v))) if nthr else "-",
            "%d" % statistics.median(conns) if conns else "-"))
    q = cells.get((payload, "quic"))
    t = cells.get((payload, "tcp"))
    if q and t:
        mq = statistics.median([x[0] for x in q])
        mt = statistics.median([x[0] for x in t])
        bad = sum(x[1] for x in q) > 0 or any(x[2] for x in q + t)
        print("%-8s %-6s ratio quic/tcp = %.3fx%s" % (
            "", "", mq / mt,
            "   <-- DISQUALIFIED, see drops/throttling" if bad else ""))
    print()
