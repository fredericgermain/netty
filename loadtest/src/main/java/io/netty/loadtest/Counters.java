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
import java.lang.management.ThreadMXBean;
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

    /**
     * Event loop thread ids, captured once so allocation can be attributed to the threads that do
     * the work.
     *
     * <p>Deliberately not "every live thread": {@code getThreadAllocatedBytes} returns -1 for a
     * thread that has exited, so a whole-process sum silently loses the allocation of anything that
     * died between two snapshots and can produce a negative delta. The event loops live for the
     * entire run, so their sum is a difference of two comparable numbers. The whole-process figure
     * is reported alongside it to catch allocation that happens somewhere else.
     */
    private static volatile long[] loopThreadIds = new long[0];

    private static final ThreadMXBean THREADS = ManagementFactory.getThreadMXBean();

    private static final com.sun.management.ThreadMXBean ALLOC_THREADS =
            THREADS instanceof com.sun.management.ThreadMXBean
                    && ((com.sun.management.ThreadMXBean) THREADS).isThreadAllocatedMemorySupported()
                    ? (com.sun.management.ThreadMXBean) THREADS : null;

    static {
        if (ALLOC_THREADS != null && !ALLOC_THREADS.isThreadAllocatedMemoryEnabled()) {
            ALLOC_THREADS.setThreadAllocatedMemoryEnabled(true);
        }
    }

    /** Called once, after the event loops exist and before the ramp. */
    static void trackLoopThreads(long[] ids) {
        loopThreadIds = ids;
    }

    final long utimeMs;
    final long stimeMs;
    final long gcCount;
    final long gcMillis;
    final long voluntaryCtxt;
    final long involuntaryCtxt;
    /** Bytes allocated on the heap by the event loop threads, cumulative since their start. */
    final long allocLoopBytes;
    /** The same for every live thread, which catches anything allocating off the event loops. */
    final long allocAllBytes;

    private Counters(long utimeMs, long stimeMs, long gcCount, long gcMillis,
                     long voluntaryCtxt, long involuntaryCtxt,
                     long allocLoopBytes, long allocAllBytes) {
        this.utimeMs = utimeMs;
        this.stimeMs = stimeMs;
        this.gcCount = gcCount;
        this.gcMillis = gcMillis;
        this.voluntaryCtxt = voluntaryCtxt;
        this.involuntaryCtxt = involuntaryCtxt;
        this.allocLoopBytes = allocLoopBytes;
        this.allocAllBytes = allocAllBytes;
    }

    /**
     * Heap allocation only. Direct memory is invisible here, which is exactly how the original
     * problem hid: {@code gcCount} stayed low through a run whose real cost was an mmap and a
     * zeroing pass per pooled chunk. Read this next to {@code pooledChunks} from the pool metric,
     * never on its own.
     */
    private static long allocatedBytes(long[] ids) {
        if (ALLOC_THREADS == null || ids.length == 0) {
            return -1;
        }
        long sum = 0;
        for (long b : ALLOC_THREADS.getThreadAllocatedBytes(ids)) {
            if (b > 0) {
                sum += b;
            }
        }
        return sum;
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
        return new Counters(utime, stime, gcCount, gcMillis, vol, invol,
                            allocatedBytes(loopThreadIds), allocatedBytes(THREADS.getAllThreadIds()));
    }

    /** This minus an earlier snapshot. */
    Counters since(Counters start) {
        return new Counters(utimeMs - start.utimeMs, stimeMs - start.stimeMs,
                            gcCount - start.gcCount, gcMillis - start.gcMillis,
                            voluntaryCtxt - start.voluntaryCtxt,
                            involuntaryCtxt - start.involuntaryCtxt,
                            allocLoopBytes - start.allocLoopBytes,
                            allocAllBytes - start.allocAllBytes);
    }

    /**
     * Per-request CPU in microseconds, which is the form the comparison is actually made in: totals
     * scale with throughput and so cannot be compared between cells that achieved different rates.
     */
    String perRequest(long requests) {
        if (requests <= 0) {
            return "utimeUsPerReq=- stimeUsPerReq=- allocBytesPerReq=- allocAllBytesPerReq=-";
        }
        return String.format("utimeUsPerReq=%.2f stimeUsPerReq=%.2f allocBytesPerReq=%.1f "
                        + "allocAllBytesPerReq=%.1f",
                utimeMs * 1000.0 / requests, stimeMs * 1000.0 / requests,
                (double) allocLoopBytes / requests, (double) allocAllBytes / requests);
    }

    @Override public String toString() {
        return String.format("utimeMs=%d stimeMs=%d gcCount=%d gcMs=%d volCtxt=%d involCtxt=%d "
                        + "allocLoopKb=%d allocAllKb=%d",
                utimeMs, stimeMs, gcCount, gcMillis, voluntaryCtxt, involuntaryCtxt,
                allocLoopBytes / 1024, allocAllBytes / 1024);
    }
}
