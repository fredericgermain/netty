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
"""Decide whether one benchmark cell passed, and write its results as tagged JSONL.

This is the part that actually gates. JMH exits 0 and writes an empty result array when every
benchmark fails to initialize, so a caller that trusts the exit status alone will report success
having measured nothing at all. That is not hypothetical: before the fix in this branch, every SSL
benchmark in the shaded jar failed to build its SslContext and JMH still exited 0.

So a cell passes only if all of the following hold, and says which one failed otherwise:

  * the JMH json exists and parses
  * it holds at least --expect results
  * every score is a finite, strictly positive number
  * the tcnative provider the image reported is consistent with what was asked for

Output is one JSON object per benchmark result, environment tags merged in, so results from
several hosts and architectures concatenate into one file and aggregate without further work.
"""
import argparse
import json
import math
import re
import os
import platform
import socket
import sys
from datetime import datetime, timezone


def parse_preflight(path):
    """The preflight file is `key=value` lines written from inside the container."""
    info = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    info[k.strip()] = v.strip()
    return info


def classify_failure(run_log_path, tcnative_version):
    """Name the mechanism, not just the verdict.

    Two very different things both end up as a failed cell, and a reader who sees only FAIL will
    conflate them:

      jvm-crash      a constructor in .init_array died during dlopen. This is the one case musl's
                     deferred-relocation behaviour does not cover -- an unresolved symbol reached
                     from an init constructor takes the process down instead of waiting to be
                     called -- so the JVM gets SIGSEGV inside JVM_LoadLibrary and the application
                     cannot catch it or fall back. Released netty-tcnative on Alpine aarch64 does
                     this, in init_have_lse_atomics via __getauxval.
      library-load   an ordinary dlopen failure, e.g. a DT_NEEDED the image cannot resolve. Netty
                     reports it as UnsatisfiedLinkError, which an application can catch.

    Same verdict, different remedy, and only the first one is uncatchable.
    """
    frame = None
    if run_log_path and os.path.exists(run_log_path):
        with open(run_log_path, errors="replace") as f:
            log = f.read()
        if "SIGSEGV" in log or "SIGBUS" in log or "SIGILL" in log:
            m = re.search(r"^# C\s+\[(.+?)\]\s*(\S+)?", log, re.M)
            frame = m.group(0).strip() if m else "signal reported, no native frame captured"
            return "jvm-crash", frame
        if "Failed to load any of the given libraries" in log or "UnsatisfiedLinkError" in log:
            return "library-load", None
    if tcnative_version.startswith("unavailable"):
        return "library-load", None
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jmh", required=True)
    ap.add_argument("--preflight", required=True)
    ap.add_argument("--run-log", default=None)
    ap.add_argument("--image", required=True)
    ap.add_argument("--tcnative", required=True)
    ap.add_argument("--mode", required=True)
    ap.add_argument("--bench", required=True)
    ap.add_argument("--expect", type=int, default=1)
    ap.add_argument("--docker-rc", type=int, default=0)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    pre = parse_preflight(args.preflight)
    failures = []
    failure_mode, crash_frame = classify_failure(args.run_log, pre.get("tcnativeVersion", ""))

    results = []
    if not os.path.exists(args.jmh):
        failures.append("JMH wrote no result file at all")
    else:
        try:
            with open(args.jmh) as f:
                results = json.load(f)
        except Exception as e:  # noqa: BLE001 - any parse problem is a cell failure
            failures.append("JMH result file did not parse: %s" % e)

    if not failures:
        if len(results) < args.expect:
            # The headline check. An empty array here is the signature of "every benchmark threw
            # during setup", which JMH reports with exit status 0.
            failures.append(
                "expected at least %d benchmark result(s), got %d -- "
                "JMH exits 0 even when every benchmark fails to initialize, so check the run log"
                % (args.expect, len(results)))
        for r in results:
            score = r.get("primaryMetric", {}).get("score")
            name = r.get("benchmark", "?")
            if score is None or not isinstance(score, (int, float)) \
                    or math.isnan(score) or math.isinf(score) or score <= 0:
                failures.append("%s produced a non-finite or non-positive score: %r" % (name, score))

    # An image asked for a tcnative flavour must actually have loaded one. Otherwise a run labelled
    # BoringSSL can quietly be something else, or nothing.
    tcnative_version = pre.get("tcnativeVersion", "")
    if args.tcnative != "none":
        if not tcnative_version or tcnative_version.startswith(("unavailable", "error")):
            failures.append("tcnative was requested as '%s' but the image reports: %s"
                            % (args.tcnative, tcnative_version or "<no preflight answer>"))
        elif args.tcnative == "boringssl" and "BoringSSL" not in tcnative_version:
            failures.append("--tcnative=boringssl but the loaded library reports '%s'"
                            % tcnative_version)
        elif args.tcnative == "openssl" and "BoringSSL" in tcnative_version:
            failures.append("--tcnative=openssl but the loaded library reports '%s'"
                            % tcnative_version)

    if args.docker_rc != 0:
        failures.append("the benchmark container exited %d" % args.docker_rc)

    tags = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": socket.gethostname(),
        "hostArch": platform.machine(),
        "image": args.image,
        "arch": pre.get("arch", "?"),
        "libc": pre.get("libc", "?"),
        "java": pre.get("java", "?"),
        "tcnative": args.tcnative,
        "tcnativeVersion": tcnative_version or None,
        "mode": args.mode,
        "benchSelector": args.bench,
        "failureMode": failure_mode,
        "crashFrame": crash_frame,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as out:
        for r in results:
            pm = r.get("primaryMetric", {})
            row = dict(tags)
            row.update({
                "benchmark": r.get("benchmark"),
                "params": r.get("params", {}),
                "score": pm.get("score"),
                "scoreError": pm.get("scoreError"),
                "unit": pm.get("scoreUnit"),
                "mode": r.get("mode", args.mode),
                "forks": r.get("forks"),
                "measurementIterations": r.get("measurementIterations"),
                "vmVersion": r.get("vmVersion"),
            })
            out.write(json.dumps(row) + "\n")

    print("-- verdict")
    print("   results   : %d" % len(results))
    if failure_mode:
        print("   mechanism : %s" % failure_mode)
        if crash_frame:
            print("   frame     : %s" % crash_frame)
    print("   tcnative  : %s" % (tcnative_version or "n/a"))
    print("   written   : %s" % args.out)
    if failures:
        for f in failures:
            print("   FAIL: %s" % f)
        print("tls-matrix: FAIL on %s / %s" % (args.image, args.tcnative))
        return 1
    print("tls-matrix: PASS on %s / %s" % (args.image, args.tcnative))
    return 0


if __name__ == "__main__":
    sys.exit(main())
