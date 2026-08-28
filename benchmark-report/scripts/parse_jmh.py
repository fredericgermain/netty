"""Print every JMH result row from the rescued jsonl files.

The point is to verify the Part A numbers in TESTS.md against raw output rather than against a
conversation summary, and in particular to settle the unit, which was recorded nowhere.
"""
import json
import os

root = "benchmark-report/jmh"
for sub in sorted(os.listdir(root)):
    d = os.path.join(root, sub)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        path = os.path.join(d, name)
        print("=== %s/%s" % (sub, name))
        try:
            content = open(path).read().strip()
        except OSError as e:
            print("   unreadable: %s" % e)
            continue
        # The files are written either as one JSON array or as one object per line, depending on
        # which runner produced them, so try both rather than guessing from the extension.
        docs = []
        try:
            parsed = json.loads(content)
            docs = parsed if isinstance(parsed, list) else [parsed]
        except json.JSONDecodeError:
            for line in content.splitlines():
                line = line.strip().rstrip(",")
                if not line:
                    continue
                try:
                    docs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        if not docs:
            print("   no parsable records (%d bytes)" % len(content))
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            bench = "%s/%s" % (doc.get("libc","?"), doc.get("tcnative","?"))
            params = doc.get("params", {}) or {}
            metric = doc
            print("   %-12s %-9s %-30s %9.2f +/- %6.2f %s" % (
                bench,
                str(params.get("sslProvider","?")),
                str(params.get("cipher", "?"))[:30],
                metric.get("score", float("nan")),
                metric.get("scoreError", float("nan")),
                metric.get("unit","?"),
            ))
