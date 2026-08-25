/*
 * Copyright 2026 The Netty Project
 *
 * The Netty Project licenses this file to you under the Apache License,
 * version 2.0 (the "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at:
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */
package io.netty.loadtest;

import java.io.IOException;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * A snapshot of where this process has spent itself: user CPU, system CPU, GC, and blocking
 * deschedules.
 *
 * <p>Two questions need this and neither can be answered by throughput alone. Whether io_uring's
 * deficit on plaintext is kernel work or netty's own Java path is a question about the split
 * between {@code stime} and {@code utime} per request. Whether the 42% run-to-run swing on TLS is
 * garbage collection is a question about pause time correlating with the slow rounds.
 *
 * <p>Deliberately built from files the kernel and JVM already maintain rather than from a profiler.
 * {@code perf} is unusable on the target host -- {@code perf_event_paranoid=4} and sudo wants a
 * password -- and {@code strace -c -f} against a JVM holding ten thousand connections would distort
 * the thing it is measuring. Reading two procfs files once per phase costs nothing and cannot
 * perturb the result. async-profiler answers the follow-up question of *which frames*; this answers
 * the prior question of *which bucket*, and that ordering keeps the expensive tool pointed
 * somewhere useful.
 */
final class Counters {

    private static final long CLK_TCK = 100;   // _SC_CLK_TCK, 100 on every Linux worth running this on

    final long utimeMs;
    final long stimeMs;
    final long gcCount;
    final long gcMillis;
    final long voluntaryCtxt;
    final long involuntaryCtxt;

    private Counters(long utimeMs, long stimeMs, long gcCount, long gcMillis,
                     long voluntaryCtxt, long involuntaryCtxt) {
        this.utimeMs = utimeMs;
        this.stimeMs = stimeMs;
        this.gcCount = gcCount;
        this.gcMillis = gcMillis;
        this.voluntaryCtxt = voluntaryCtxt;
        this.involuntaryCtxt = involuntaryCtxt;
    }

    static Counters snapshot() {
        long utime = 0;
        long stime = 0;
        try {
            // /proc/self/stat, fields 14 and 15 (1-based), in clock ticks. The comm field can
            // contain spaces and parentheses, so split after the closing paren rather than
            // tokenising the whole line -- a JVM whose argv[0] contained a space would otherwise
            // shift every subsequent index and silently produce nonsense.
            String stat = new String(Files.readAllBytes(Paths.get("/proc/self/stat")));
            String after = stat.substring(stat.lastIndexOf(')') + 2);
            String[] f = after.split(" ");
            utime = Long.parseLong(f[11]) * 1000 / CLK_TCK;   // field 14 -> index 11 after the split
            stime = Long.parseLong(f[12]) * 1000 / CLK_TCK;   // field 15
        } catch (IOException | RuntimeException ignored) {
            // Not Linux, or procfs unreadable. Zeros are obvious in the output; guessing is not.
        }

        long vol = 0;
        long invol = 0;
        // Summed over /proc/self/task/*, not read from /proc/self/status. That file reports the
        // MAIN thread only, and in netty the main thread does nothing after bind -- every read,
        // write and deschedule happens on an event loop thread. Reading the process file gives a
        // confident-looking zero, which is worse than no number at all.
        try (java.util.stream.Stream<java.nio.file.Path> tasks =
                     Files.list(Paths.get("/proc/self/task"))) {
            for (java.nio.file.Path task : (Iterable<java.nio.file.Path>) tasks::iterator) {
                try {
                    for (String line : Files.readAllLines(task.resolve("status"))) {
                        if (line.startsWith("voluntary_ctxt_switches:")) {
                            vol += Long.parseLong(line.split("\\s+")[1]);
                        } else if (line.startsWith("nonvoluntary_ctxt_switches:")) {
                            invol += Long.parseLong(line.split("\\s+")[1]);
                        }
                    }
                } catch (IOException | RuntimeException perThread) {
                    // A thread can exit between listing and reading; skip it rather than abandon
                    // the whole sum.
                }
            }
        } catch (IOException | RuntimeException ignored) {
            // as above
        }

        long gcCount = 0;
        long gcMillis = 0;
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            long c = gc.getCollectionCount();
            long t = gc.getCollectionTime();
            if (c > 0) {
                gcCount += c;
            }
            if (t > 0) {
                gcMillis += t;
            }
        }
        return new Counters(utime, stime, gcCount, gcMillis, vol, invol);
    }

    /** This minus an earlier snapshot. */
    Counters since(Counters start) {
        return new Counters(utimeMs - start.utimeMs, stimeMs - start.stimeMs,
                            gcCount - start.gcCount, gcMillis - start.gcMillis,
                            voluntaryCtxt - start.voluntaryCtxt,
                            involuntaryCtxt - start.involuntaryCtxt);
    }

    /**
     * Per-request CPU in microseconds, which is the form the comparison is actually made in: totals
     * scale with throughput and so cannot be compared between cells that achieved different rates.
     */
    String perRequest(long requests) {
        if (requests <= 0) {
            return "utimeUsPerReq=- stimeUsPerReq=-";
        }
        return String.format("utimeUsPerReq=%.2f stimeUsPerReq=%.2f",
                utimeMs * 1000.0 / requests, stimeMs * 1000.0 / requests);
    }

    @Override public String toString() {
        return String.format("utimeMs=%d stimeMs=%d gcCount=%d gcMs=%d volCtxt=%d involCtxt=%d",
                utimeMs, stimeMs, gcCount, gcMillis, voluntaryCtxt, involuntaryCtxt);
    }
}
