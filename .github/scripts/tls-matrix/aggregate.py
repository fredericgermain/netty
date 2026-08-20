#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# Copyright 2026 The Netty Project
#
# The Netty Project licenses this file to you under the Apache License,
# version 2.0 (the "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at:
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
# ----------------------------------------------------------------------------
"""Merge tls-matrix jsonl into two markdown tables: what ran, and what it measured.

Takes files or directories, from any number of hosts. Every row is already stamped with host,
arch, libc, image and tcnative, which is what makes results from an x86_64 runner and an aarch64
one concatenate without any join.

Two tables, because the run answers two different questions:

  coverage  did every cell actually produce numbers, and where it did not, by what mechanism.
            This is the release gate's view.
  scores    the same benchmark and parameters across environments, side by side. This is the
            "does musl or the base image show up in TLS numbers" view.

usage: aggregate.py results/ [more...] [--bench REGEX] [--out FILE]
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import OrderedDict


def load(paths):
    rows = []
    for p in paths:
        files = []
        if os.path.isdir(p):
            files = sorted(glob.glob(os.path.join(p, "*.jsonl")))
        else:
            files = [p]
        for f in files:
            with open(f) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        rows.append(json.loads(line))
    return rows


def env_key(r):
    """The environment a row was measured in, as one short label."""
    return "%s/%s/%s" % (r.get("arch", "?"), r.get("libc", "?"),
                         (r.get("image") or "?").split("/")[-1])


def cell_key(r):
    return (r.get("host", "?"), env_key(r), r.get("tcnative", "?"))


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(out)


def coverage(rows):
    cells = OrderedDict()
    for r in rows:
        k = cell_key(r)
        c = cells.setdefault(k, {"results": 0, "ok": True, "mode": None, "frame": None,
                                 "tcv": r.get("tcnativeVersion")})
        if r.get("benchmark"):
            c["results"] += 1
        if r.get("ok") is False:
            c["ok"] = False
        # failureMode is a property of the cell, not of an individual result row.
        if r.get("failureMode"):
            c["mode"] = r["failureMode"]
            c["frame"] = r.get("crashFrame")

    body = []
    for (host, env, tc), c in cells.items():
        verdict = "PASS" if c["ok"] else "**FAIL**"
        why = c["mode"] or ""
        if c["mode"] == "jvm-crash" and c["frame"]:
            # The frame is the whole value of this row: it names the constructor that died.
            why = "jvm-crash — `%s`" % re.sub(r"^# C\s+", "", c["frame"])
        body.append([host, env, tc, c["results"], (c["tcv"] or "-")[:28], verdict, why])
    return md_table(["host", "arch/libc/image", "tcnative", "results", "loaded", "verdict", "mechanism"],
                    body)


def scores(rows, bench_filter):
    rows = [r for r in rows if r.get("benchmark") and r.get("score") is not None]
    if bench_filter:
        rows = [r for r in rows if re.search(bench_filter, r["benchmark"])]
    if not rows:
        return "_no scored results_"

    envs = sorted({env_key(r) for r in rows})
    unit = rows[0].get("unit", "")
    keys = OrderedDict()
    for r in rows:
        p = r.get("params", {})
        k = (r["benchmark"].split(".")[-1],
             p.get("sslProvider", "-"),
             p.get("cipher", "-"),
             p.get("messageSize", "-"))
        keys.setdefault(k, {})[env_key(r)] = r["score"]

    body = []
    for (bench, prov, cipher, size), by_env in keys.items():
        # TLS 1.3 renamed its suites, so the prefix is a reliable protocol label.
        proto = "1.3" if cipher.startswith(("TLS_AES_", "TLS_CHACHA20_")) else "1.2"
        cells = ["%.1f" % by_env[e] if e in by_env else "-" for e in envs]
        row = [bench, proto, prov, cipher]
        if size != "-":
            row.append(size)
        body.append(row + cells)
    headers = ["benchmark", "tls", "provider", "cipher"]
    if any(k[3] != "-" for k in keys):
        headers.append("bytes")
    return md_table(headers + ["%s (%s)" % (e, unit) for e in envs], body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--bench", default=None, help="regex to restrict the score table")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    rows = load(args.paths)
    if not rows:
        print("no rows found in %s" % ", ".join(args.paths), file=sys.stderr)
        return 2

    text = "\n\n".join([
        "## Coverage", coverage(rows),
        "## Scores", scores(rows, args.bench),
        "_%d result rows from %d cell(s)._" % (
            len([r for r in rows if r.get("benchmark")]),
            len({cell_key(r) for r in rows})),
    ])
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
        print("written to %s" % args.out)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
