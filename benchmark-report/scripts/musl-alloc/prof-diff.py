"""Diff the musl and glibc QUIC server profiles, normalised per request.

Percentages cannot be compared directly here: the two runs did different amounts of work in the same
wall time, so a frame can hold a smaller share of musl's profile while costing more per request. The
question is which frames cost musl MORE PER REQUEST, so every frame is divided by that run's request
count before the comparison.

Both profiles account for their own CPU (about 83k samples at 1ms against roughly 80 core-seconds),
which is the check that makes them comparable at all. On this host async-profiler once under-reported
one configuration by 3.5x while matching another exactly, so that check is not a formality.
"""
import os
import sys
from collections import defaultdict

OUT = "/tmp/quicprof"
# Requests completed during each 20 s profiled window, from the STEADY line of the same run.
REQS = {"musl": 50203 * 20, "glibc": 59627 * 20}


def load(tag):
    path = os.path.join(OUT, tag + ".collapsed")
    self_time = defaultdict(int)
    total = 0
    for line in open(path):
        line = line.rstrip("\n")
        if not line:
            continue
        stack, _, count = line.rpartition(" ")
        try:
            n = int(count)
        except ValueError:
            continue
        frames = stack.split(";")
        # Self time: attribute to the leaf. Inclusive time would double-count shared ancestry and
        # hide exactly the leaf-level differences being looked for.
        self_time[frames[-1]] += n
        total += n
    return self_time, total


musl, musl_total = load("musl")
glibc, glibc_total = load("glibc")
print("samples: musl=%d glibc=%d" % (musl_total, glibc_total))
print("per-request samples: musl=%.4f glibc=%.4f  -> musl uses %.0f%% more CPU per request\n"
      % (musl_total / REQS["musl"], glibc_total / REQS["glibc"],
         100 * ((musl_total / REQS["musl"]) / (glibc_total / REQS["glibc"]) - 1)))

rows = []
for frame in set(musl) | set(glibc):
    m = musl.get(frame, 0) / REQS["musl"]
    g = glibc.get(frame, 0) / REQS["glibc"]
    rows.append((m - g, m, g, frame))

# Sorted by absolute per-request difference, which is what actually adds up to the deficit. A frame
# with a huge ratio but a tiny absolute cost explains nothing.
rows.sort(reverse=True)
print("Frames costing musl MORE per request (top 18):")
print("  %-11s %-11s %-9s %s" % ("musl/req", "glibc/req", "delta", "frame"))
for d, m, g, frame in rows[:18]:
    print("  %-11.5f %-11.5f %+9.5f %s" % (m, g, d, frame[:95]))

print("\nFrames costing musl LESS per request (top 6):")
for d, m, g, frame in rows[-6:]:
    print("  %-11.5f %-11.5f %+9.5f %s" % (m, g, d, frame[:95]))

# Roll the leaves up by owner, because the interesting question is whether the extra cost sits in
# libc itself, in the kernel, or in netty's Java.
# musl resolves nearly everything into the single ld-musl-x86_64.so.1 image while glibc splits
# malloc, free and the mem* family out as named symbols. Bucketing on the image name alone therefore
# credits glibc's allocator to "other" and overstates the libc gap, so named libc entry points are
# matched explicitly.
LIBC_SYMS = {
    "malloc", "free", "calloc", "realloc", "memcpy", "memmove", "memset", "memcmp",
    "strlen", "strcmp", "__memcpy_avx_unaligned_erms", "__memset_avx2_unaligned_erms",
    "posix_memalign", "aligned_alloc", "mmap", "munmap", "pthread_mutex_lock",
    "pthread_mutex_unlock", "pthread_cond_signal", "pthread_cond_wait",
}


def bucket(frame):
    if frame.endswith("_[k]"):
        return "kernel"
    if "ld-musl" in frame or "libc.so" in frame:
        return "libc"
    if frame in LIBC_SYMS or frame.startswith("__memcpy") or frame.startswith("__memset"):
        return "libc"
    if frame.startswith("io/netty"):
        return "netty java"
    if frame.startswith("<") or "::" in frame:
        return "quiche/rust"
    if "/" in frame:
        return "jvm/other native"
    return "java/other"


agg = defaultdict(lambda: [0.0, 0.0])
for frame in set(musl) | set(glibc):
    b = bucket(frame)
    agg[b][0] += musl.get(frame, 0) / REQS["musl"]
    agg[b][1] += glibc.get(frame, 0) / REQS["glibc"]
print("\nPer-request cost by owner:")
print("  %-18s %-11s %-11s %s" % ("bucket", "musl/req", "glibc/req", "delta"))
for b, (m, g) in sorted(agg.items(), key=lambda kv: kv[1][0] - kv[1][1], reverse=True):
    print("  %-18s %-11.5f %-11.5f %+.5f" % (b, m, g, m - g))
