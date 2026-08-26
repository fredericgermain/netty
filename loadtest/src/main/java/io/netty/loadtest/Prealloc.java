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

import io.netty.buffer.ByteBuf;
import io.netty.buffer.PoolArenaMetric;
import io.netty.buffer.PoolChunkListMetric;
import io.netty.buffer.PoolChunkMetric;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.EventLoopGroup;
import io.netty.util.concurrent.EventExecutor;
import io.netty.util.concurrent.Future;

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;

/**
 * Everything that exists so the harness itself stops being a variable.
 *
 * <p>Stack walking at a 256 KB payload found the load generator's own top page-zeroing site was
 * {@code RequestLoop.sendClosed -> PooledUnsafeDirectByteBuf.writeZero -> Unsafe.setMemory0}: the
 * harness built its payload by memsetting a fresh buffer on every single request. That is pure
 * measurement overhead, it scales with payload, and payload was the axis under test, so it
 * contaminated exactly the result it was being used to establish. Everything here removes a source
 * of allocation or of run-time variation from the measuring instrument rather than from netty.
 *
 * <p>Every entry point aborts rather than degrading. A cell labelled pre-allocated that quietly was
 * not would be worse than no cell at all, and the same rule already governs the transport selection
 * and the TLS provider.
 */
final class Prealloc {

    private Prealloc() { }

    /**
     * Warm-up buffers held for the process lifetime, one per arena chunk, so the chunk cannot be
     * unmapped again.
     *
     * <p>Netty destroys a chunk the moment it goes fully free: {@code q000.prevList(null)} in
     * {@code PoolArena}, so {@code PoolChunkList.free} on an emptied q000 chunk falls through to
     * {@code arena.destroyChunk}. A warm-up that allocated and then released everything would
     * therefore leave the arena exactly as it found it. Holding one small share of each chunk keeps
     * its usage above q000's 1% floor and pins the mapping.
     */
    private static final List<ByteBuf> PINNED = new ArrayList<ByteBuf>();

    // ------------------------------------------------------------------ payload

    /**
     * Builds the one frame every request sends: a 4-byte big-endian length header followed by the
     * body, laid out exactly as {@code LengthFieldPrepender} would have laid it out.
     *
     * <p>Carrying the header inside the same buffer is what lets the prepender leave both pipelines.
     * {@code LengthFieldPrepender.encode} allocates a header buffer from {@code ctx.alloc()} per
     * write and then emits two messages instead of one, so it costs an allocation and an extra
     * outbound buffer entry on every request at both ends.
     *
     * <p>Pooled rather than unpooled, which looks backwards for a buffer allocated once and never
     * freed. The reason is the per-request derivation: {@code PooledByteBuf.retainedSlice} goes to
     * {@code PooledSlicedByteBuf.newInstance}, which comes off a {@code Recycler} and allocates
     * nothing in steady state, while the unpooled path is a plain {@code new UnpooledSlicedByteBuf}
     * per call. For the same reason the buffer is not wrapped with {@code asReadOnly()}: that
     * returns a fresh {@code ReadOnlyByteBuf} wrapper on every derivation. Nothing on either side
     * writes to it, so the immutability is by construction rather than by type.
     *
     * <p>Filled with a xorshift pattern, not zeros. Zero pages are special-cased in several layers
     * -- kernel same-page merging, transparent huge page zeroing, and any compression on the path --
     * and a benchmark should not be measuring a fast path for zeros.
     */
    static ByteBuf buildFrame(int payload) {
        ByteBuf b = PooledByteBufAllocator.DEFAULT.directBuffer(payload + 4, payload + 4);
        b.writeInt(payload);
        long s = 0x9E3779B97F4A7C15L;
        while (b.writableBytes() >= 8) {
            s ^= s << 13;
            s ^= s >>> 7;
            s ^= s << 17;
            b.writeLong(s);
        }
        while (b.writableBytes() > 0) {
            s ^= s << 13;
            s ^= s >>> 7;
            s ^= s << 17;
            b.writeByte((byte) s);
        }
        return b;
    }

    // ------------------------------------------------------------------ arenas

    /** Live chunks across every direct arena. The quantity the warm-up has to make stop moving. */
    static int directChunks() {
        int chunks = 0;
        for (PoolArenaMetric arena : PooledByteBufAllocator.DEFAULT.metric().directArenas()) {
            for (PoolChunkListMetric list : arena.chunkLists()) {
                for (PoolChunkMetric ignored : list) {
                    chunks++;
                }
            }
        }
        return chunks;
    }

    static String poolState() {
        return String.format("usedDirectMb=%d pooledChunks=%d",
                PooledByteBufAllocator.DEFAULT.metric().usedDirectMemory() / (1024 * 1024),
                directChunks());
    }

    /**
     * Forces the arena chunks the run will need into existence before the ramp, and pins them.
     *
     * <p>Run on the event loop threads and not on the caller. A pooled allocation is served from
     * the arena bound to the allocating thread, so warming up from {@code main} would grow one arena
     * and leave the arenas the event loops actually use untouched -- a warm-up that reports success
     * and changes nothing.
     *
     * <p>Each buffer is touched one byte per page. Netty allocates direct memory through
     * {@code allocateDirectNoCleaner}, which is {@code Unsafe.allocateMemory}: the mapping exists
     * but the pages are not resident, so without the touch the first-touch faults would simply move
     * from the ramp into the steady window rather than out of the run.
     *
     * @param bufSize the exact size the run allocates, so the warm-up lands in the same size class
     * @return a description of what it did, for the READY line
     */
    static String warmArenas(EventLoopGroup group, long totalBytes, int bufSize) {
        int loops = 0;
        for (EventExecutor ignored : group) {
            loops++;
        }
        if (loops == 0) {
            throw new IllegalStateException("--prealloc warm-up found no event loops in " + group);
        }
        int chunkSize = PooledByteBufAllocator.DEFAULT.metric().chunkSize();
        // Twice as dense as the arithmetic requires. The normalised size class for a request of
        // bufSize is at least bufSize, so a chunk holds at most chunkSize/bufSize of them; pinning
        // every (chunkSize / 2 / bufSize)-th buffer keeps at least one per chunk even when the
        // allocator rounds the request up a class or splits a run across chunks.
        final int pinEvery = Math.max(1, chunkSize / Math.max(1, 2 * bufSize));
        final int perLoop = (int) Math.max(1, totalBytes / loops / bufSize);

        int before = directChunks();
        List<Future<?>> futures = new ArrayList<Future<?>>(loops);
        for (EventExecutor loop : group) {
            futures.add(loop.submit(new Runnable() {
                @Override public void run() {
                    List<ByteBuf> burst = new ArrayList<ByteBuf>(perLoop);
                    for (int i = 0; i < perLoop; i++) {
                        ByteBuf b = PooledByteBufAllocator.DEFAULT.directBuffer(bufSize, bufSize);
                        for (int off = 0; off < bufSize; off += 4096) {
                            b.setByte(off, 1);
                        }
                        b.setByte(bufSize - 1, 1);
                        burst.add(b);
                    }
                    for (int i = 0; i < burst.size(); i++) {
                        if (i % pinEvery == 0) {
                            synchronized (PINNED) {
                                PINNED.add(burst.get(i));
                            }
                        } else {
                            burst.get(i).release();
                        }
                    }
                }
            }));
        }
        int peak = 0;
        for (Future<?> f : futures) {
            f.syncUninterruptibly();
            peak = Math.max(peak, directChunks());
        }
        int after = directChunks();
        if (after <= before) {
            throw new IllegalStateException("--prealloc warm-up allocated " + (perLoop * loops)
                    + " buffers of " + bufSize + " B and the direct arenas did not grow ("
                    + before + " -> " + after + " chunks). Refusing to run a cell labelled prealloc "
                    + "whose arenas were not warmed.");
        }
        return String.format("warmChunks=%d->%d(peak %d) warmAllocated=%d warmPinned=%d "
                        + "warmPinnedKb=%d warmBufSize=%d pinEvery=%d",
                before, after, peak, perLoop * loops, PINNED.size(),
                (long) PINNED.size() * bufSize / 1024, bufSize, pinEvery);
    }

    // ------------------------------------------------------------------ jvm

    /**
     * Refuses to run a cell labelled {@code --jvm-tuned} unless the JVM was actually started tuned.
     *
     * <p>The three settings cannot be applied from inside the process, so the only honest thing the
     * process can do is check that the launcher applied them. {@code -Xms} below {@code -Xmx} means
     * the heap grows during the run; without {@code AlwaysPreTouch} its pages fault in during the
     * run; and an unset {@code MaxDirectMemorySize} defaults to the heap maximum, which makes the
     * direct-memory ceiling an accident of the heap setting rather than a stated condition.
     */
    static void requireTunedJvm() {
        List<String> argv = ManagementFactory.getRuntimeMXBean().getInputArguments();
        String xms = null;
        String xmx = null;
        boolean preTouch = false;
        boolean maxDirect = false;
        for (String s : argv) {
            if (s.startsWith("-Xms")) {
                xms = s.substring(4);
            } else if (s.startsWith("-Xmx")) {
                xmx = s.substring(4);
            } else if (s.equals("-XX:+AlwaysPreTouch")) {
                preTouch = true;
            } else if (s.startsWith("-XX:MaxDirectMemorySize=")) {
                maxDirect = true;
            }
        }
        StringBuilder missing = new StringBuilder();
        if (xms == null || xmx == null || !xms.equalsIgnoreCase(xmx)) {
            missing.append(" -Xms==-Xmx(got Xms=").append(xms).append(" Xmx=").append(xmx).append(')');
        }
        if (!preTouch) {
            missing.append(" -XX:+AlwaysPreTouch");
        }
        if (!maxDirect) {
            missing.append(" -XX:MaxDirectMemorySize=");
        }
        if (missing.length() > 0) {
            throw new IllegalStateException("--jvm-tuned was requested but the JVM was not started "
                    + "with:" + missing + ". Full argv: " + argv);
        }
    }

    /**
     * Leak detection allocates on every buffer it samples, so a measurement run must not have it on.
     * Reported rather than enforced, because developing the reference counting in the request path
     * needs {@code paranoid} and the flag would then have to be fought.
     */
    static String leakDetection() {
        return io.netty.util.ResourceLeakDetector.getLevel().name().toLowerCase();
    }
}
