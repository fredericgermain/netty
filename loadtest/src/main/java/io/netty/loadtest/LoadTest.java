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

import io.netty.bootstrap.AbstractBootstrap;
import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.AdaptiveRecvByteBufAllocator;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFuture;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.FixedRecvByteBufAllocator;
import io.netty.channel.MultiThreadIoEventLoopGroup;
import io.netty.channel.RecvByteBufAllocator;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.LengthFieldPrepender;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslHandler;
import io.netty.util.concurrent.EventExecutor;
import io.netty.util.concurrent.Future;
import org.HdrHistogram.Histogram;

import java.net.InetSocketAddress;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * A load generator for many concurrent TLS connections.
 *
 * <p>This exists because the in-memory {@code SSLEngine} pair in netty's microbench measures one
 * handshake at a time in one process. It says nothing about what happens when ten thousand
 * connections arrive at once, which is where the transport (NIO / epoll / io_uring) finally has
 * something to say: bulk transfer over a handful of connections issues so few syscalls that all
 * three measure identically, and io_uring's whole advantage is amortising syscalls.
 *
 * <p>Two phases, reported separately rather than averaged into one number:
 *
 * <ul>
 *   <li><b>ramp</b> -- open every connection and complete every TLS handshake. Reports
 *       connections/s. With TLS this is the dominant setup cost and is a far more realistic
 *       handshake figure than an in-memory pair gives, because it includes accept, the event loop
 *       and real sockets.</li>
 *   <li><b>steady</b> -- a closed loop on each established connection for a fixed duration, with a
 *       small payload so the test stays syscall-bound rather than bandwidth-bound. Reports
 *       requests/s and latency percentiles.</li>
 * </ul>
 *
 * <p>Closed loop, one request in flight per connection: latency is then service time under the
 * offered concurrency, and throughput follows from it, which is the easiest shape to reason about.
 *
 * <h2>{@code --prealloc}: the harness as a variable</h2>
 *
 * <p>Off by default, and that default is load bearing. Every number recorded in
 * {@code loadtest/README.md} before this flag existed was taken without it, and the old path is
 * kept byte for byte so those numbers stay reproducible rather than merely quotable.
 *
 * <p>On, it removes the harness's own per-request allocation: one frame built at startup and
 * re-derived per request instead of a fresh buffer memset to zero, no {@code LengthFieldPrepender},
 * void promises, per-event-loop latency histograms, a primitive queue for open-loop due times, and
 * an arena warm-up. See {@link Prealloc}. The wire format is identical either way -- a 4-byte
 * big-endian length then the body -- so a pre-allocated client can drive a default server and the
 * difference can be attributed to one side.
 */
public final class LoadTest {

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            usage();
            System.exit(2);
        }
        Args a = Args.parse(args);
        switch (args[0]) {
            case "server": server(a); break;
            case "client": client(a); break;
            default: usage(); System.exit(2);
        }
    }

    private static void usage() {
        System.err.println("usage:");
        System.err.println("  server --transport=nio|epoll|io_uring --tls=none|jdk|openssl "
                + "[--port=9999] [--backlog=8192] [--threads=N]");
        System.err.println("  client --transport=... --tls=... [--host=127.0.0.1] [--port=9999]");
        System.err.println("         [--connections=10000] [--duration=15] [--payload=1024] [--threads=N]");
        System.err.println("         [--rate=N]  total req/s; omit to saturate (throughput only, latency invalid)");
        System.err.println("  --ring-size=N   io_uring ring entries, default 16384. Swept at 10k connections,");
        System.err.println("                  4096/16384/32768 measured within 1.5% of each other.");
        System.err.println("  --prealloc      remove the harness's own per-request allocation. Needs --payload on");
        System.err.println("                  the server too, and --connections or --warmup-mb to size the warm-up.");
        System.err.println("  --warmup-mb=N   pooled direct memory to force into existence before the ramp.");
        System.err.println("  --fixed-rcvbuf=N  FixedRecvByteBufAllocator instead of the adaptive one. Mutually");
        System.err.println("                  exclusive with --rcvbuf-max.");
        System.err.println("  --jvm-tuned     assert the JVM was started with -Xms==-Xmx, +AlwaysPreTouch and an");
        System.err.println("                  explicit -XX:MaxDirectMemorySize; abort if it was not.");
    }

    // ------------------------------------------------------------------ server

    private static void server(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        final boolean prealloc = a.flag("prealloc");
        if (a.flag("jvm-tuned")) {
            Prealloc.requireTunedJvm();
        }
        final SslContext ssl = Tls.serverContext(a.get("tls", "none"));

        int ringSize = a.getInt("ring-size", 16384);
        // 0 means no provided buffer ring, which is netty's default and also the configuration in
        // which multishot recv never arms. Kept as the default here so the existing numbers stay
        // comparable, and swept explicitly rather than switched on silently.
        int bufRing = a.getInt("buffer-ring", 0);
        int bufSize = a.getInt("buffer-ring-size", 2048);
        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, t.ioHandler(ringSize, bufRing, bufSize));
        final EventLoopGroup worker =
                new MultiThreadIoEventLoopGroup(a.threads(), t.ioHandler(ringSize, bufRing, bufSize));
        Counters.trackLoopThreads(loopThreadIds(worker));
        try {
            ServerBootstrap b = new ServerBootstrap()
                    .group(boss, worker)
                    .channel(t.serverChannel())
                    // Netty's default is 200. Ten thousand simultaneous connects overflow that
                    // instantly and the kernel starts dropping SYNs, which shows up as a stalled
                    // ramp rather than as an error.
                    .option(ChannelOption.SO_BACKLOG, a.getInt("backlog", 8192))
                    .option(ChannelOption.SO_REUSEADDR, true)
                    .childOption(ChannelOption.TCP_NODELAY, true)
                    .childOption(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
                    .childHandler(new ChannelInitializer<Channel>() {
                        @Override protected void initChannel(Channel ch) {
                            if (ssl != null) {
                                ch.pipeline().addLast(ssl.newHandler(ch.alloc()));
                            }
                            // With --prealloc the length header is not stripped and not re-added:
                            // the frame goes back out exactly as it arrived, which deletes
                            // LengthFieldPrepender's per-write header allocation and its second
                            // outbound message. The bytes on the wire are the same either way.
                            ch.pipeline().addLast(prealloc
                                    ? new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 0)
                                    : new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 4));
                            if (!prealloc) {
                                ch.pipeline().addLast(new LengthFieldPrepender(4));
                            }
                            ch.pipeline().addLast(new EchoHandler(prealloc));
                        }
                    });
            applyZeroCopy(b, t, a);
            String recvAlloc = applyBufferTuning(b, a, prealloc);
            String warm = prealloc ? warmUp(a, worker) : "warm=off";
            Channel ch = b.bind(new InetSocketAddress(a.get("host", "0.0.0.0"), a.getInt("port", 9999)))
                          .sync().channel();
            // Cumulative snapshots on a fixed cadence, rather than one total at shutdown. The
            // server outlives several phases and a single total would conflate the ramp -- ten
            // thousand TLS handshakes -- with the steady state, which is the part under
            // comparison. Any two lines give a delta of both CPU and requests, so the caller can
            // bracket whichever window it cares about.
            worker.next().scheduleAtFixedRate(() -> System.out.printf(
                    "SERVERCPU tMs=%d requests=%d %s %s%n",
                    System.currentTimeMillis(), SERVER_REQUESTS.get(), Counters.snapshot(),
                    Prealloc.poolState()),
                    2, 2, TimeUnit.SECONDS);

            System.out.println("READY transport=" + t + " tls=" + a.get("tls", "none")
                    + " backlog=" + a.getInt("backlog", 8192) + " threads=" + a.threads()
                    + " ringSize=" + ringSize + " bufferRing=" + bufRing
                    + (bufRing > 0 ? " bufferSize=" + bufSize : "")
                    + " sndbuf=" + a.getInt("sndbuf", 0)
                    + " rcvbufMax=" + a.getInt("rcvbuf-max", 0)
                    + " prealloc=" + prealloc + " jvmTuned=" + a.flag("jvm-tuned")
                    + " " + recvAlloc + " " + warm
                    + " leakDetection=" + Prealloc.leakDetection()
                    + " " + Prealloc.poolState());
            System.out.flush();
            ch.closeFuture().sync();
        } finally {
            boss.shutdownGracefully();
            worker.shutdownGracefully();
        }
    }

    /** Counts what the server has echoed, so its CPU deltas can be divided by something. */
    private static final AtomicLong SERVER_REQUESTS = new AtomicLong();

    /** Echoes the frame straight back. Nothing allocated, nothing copied. */
    private static final class EchoHandler extends ChannelInboundHandlerAdapter {
        private final boolean voidPromise;

        EchoHandler(boolean voidPromise) {
            this.voidPromise = voidPromise;
        }

        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            SERVER_REQUESTS.incrementAndGet();
            if (voidPromise) {
                // ctx.writeAndFlush(msg) with no promise calls newPromise(), which is a
                // DefaultChannelPromise per request. The void promise is one instance per channel
                // and still routes failures to exceptionCaught, which is the only thing this
                // handler does with them.
                ctx.writeAndFlush(msg, ctx.voidPromise());
            } else {
                ctx.writeAndFlush(msg);
            }
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }
    }

    // ------------------------------------------------------------------ client

    private static void client(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        final boolean prealloc = a.flag("prealloc");
        if (a.flag("jvm-tuned")) {
            Prealloc.requireTunedJvm();
        }
        final SslContext ssl = Tls.clientContext(a.get("tls", "none"));

        int connections = a.getInt("connections", 10000);
        int durationSec = a.getInt("duration", 15);
        final int payload = a.getInt("payload", 1024);
        // Total requests/s across all connections. Absent => closed loop: saturate and report
        // throughput only, because closed-loop latency is queue depth rather than service time.
        int rate = a.getInt("rate", 0);
        final long intervalNanos = rate == 0 ? 0 : (long) (1e9 * connections / rate);
        final String host = a.get("host", "127.0.0.1");
        final int port = a.getInt("port", 9999);

        EventLoopGroup group = new MultiThreadIoEventLoopGroup(a.threads(),
                t.ioHandler(a.getInt("ring-size", 16384), a.getInt("buffer-ring", 0),
                            a.getInt("buffer-ring-size", 2048)));
        Counters.trackLoopThreads(loopThreadIds(group));
        // Recorded across every connection. Values are microseconds; three significant digits is
        // plenty for percentiles and keeps the histogram small enough to be free.
        Histogram latency = new Histogram(1, TimeUnit.SECONDS.toMicros(60), 3);
        // With --prealloc every event loop records into its own histogram and they are summed once
        // at the end. HdrHistogram's recordValue on a pre-sized histogram allocates nothing, but
        // the shared instance is not thread safe, so the default path takes a lock on it per
        // request; splitting per loop removes the lock without changing what is recorded.
        final Map<EventExecutor, Histogram> perLoop =
                prealloc ? new IdentityHashMap<EventExecutor, Histogram>() : null;
        if (prealloc) {
            for (EventExecutor e : group) {
                perLoop.put(e, new Histogram(1, TimeUnit.SECONDS.toMicros(60), 3));
            }
        }
        final AtomicLong requests = new AtomicLong();
        final AtomicLong errors = new AtomicLong();
        List<Channel> channels = new ArrayList<Channel>(connections);

        final ByteBuf frame = prealloc ? Prealloc.buildFrame(payload) : null;
        String warm = prealloc ? warmUp(a, group) : "warm=off";

        try {
            Bootstrap b = new Bootstrap()
                    .group(group)
                    .channel(t.clientChannel())
                    .option(ChannelOption.TCP_NODELAY, true)
                    .option(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
                    .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 30000);
            applyZeroCopy(b, t, a);
            String recvAlloc = applyBufferTuning(b, a, prealloc);

            System.out.println("CLIENTCFG transport=" + t + " tls=" + a.get("tls", "none")
                    + " connections=" + connections + " payload=" + payload
                    + " threads=" + a.threads() + " rate=" + rate
                    + " prealloc=" + prealloc + " jvmTuned=" + a.flag("jvm-tuned")
                    + " " + recvAlloc + " " + warm
                    + " leakDetection=" + Prealloc.leakDetection()
                    + " " + Prealloc.poolState());
            System.out.flush();

            // ---------------- ramp
            final CountDownLatch ready = new CountDownLatch(connections);
            final Histogram sharedLatency = latency;
            long rampStart = System.nanoTime();
            List<ChannelFuture> pending = new ArrayList<ChannelFuture>(connections);
            for (int i = 0; i < connections; i++) {
                Bootstrap bb = b.clone().handler(new ChannelInitializer<Channel>() {
                    @Override protected void initChannel(Channel ch) {
                        if (ssl != null) {
                            SslHandler h = ssl.newHandler(ch.alloc(), host, port);
                            ch.pipeline().addLast(h);
                            // Count the connection ready only once TLS is up, so the ramp number
                            // is connections-and-handshakes rather than TCP connects.
                            h.handshakeFuture().addListener((Future<Channel> f) -> {
                                if (!f.isSuccess()) {
                                    errors.incrementAndGet();
                                }
                                ready.countDown();
                            });
                        }
                        ch.pipeline().addLast(prealloc
                                ? new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 0)
                                : new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 4));
                        if (!prealloc) {
                            ch.pipeline().addLast(new LengthFieldPrepender(4));
                        }
                        ch.pipeline().addLast(new RequestLoop(sharedLatency, perLoop, requests,
                                errors, payload, intervalNanos, frame));
                    }
                });
                ChannelFuture cf = bb.connect(host, port);
                if (ssl == null) {
                    cf.addListener(f -> {
                        if (!f.isSuccess()) {
                            errors.incrementAndGet();
                        }
                        ready.countDown();
                    });
                } else {
                    cf.addListener(f -> {
                        if (!f.isSuccess()) {
                            errors.incrementAndGet();
                            ready.countDown();   // handshake listener will never fire
                        }
                    });
                }
                pending.add(cf);
            }
            if (!ready.await(120, TimeUnit.SECONDS)) {
                System.err.println("ramp did not complete within 120s; " + ready.getCount() + " outstanding");
            }
            long rampNanos = System.nanoTime() - rampStart;
            for (ChannelFuture cf : pending) {
                if (cf.isSuccess()) {
                    channels.add(cf.channel());
                }
            }

            System.out.printf("RAMP  connections=%d established=%d errors=%d wallMs=%d connPerSec=%.0f "
                            + "%s%n",
                    connections, channels.size(), errors.get(),
                    TimeUnit.NANOSECONDS.toMillis(rampNanos),
                    channels.size() / (rampNanos / 1e9), Prealloc.poolState());
            System.out.flush();

            // ---------------- steady
            latency.reset();
            if (prealloc) {
                for (Histogram h : perLoop.values()) {
                    h.reset();
                }
            }
            requests.set(0);
            Counters before = Counters.snapshot();
            String poolBefore = Prealloc.poolState();
            long steadyStart = System.nanoTime();
            // Stagger the open-loop tickers across one interval, or 10k connections all fire in
            // the same millisecond and the load arrives as a spike rather than at the target rate.
            long stagger = 0;
            long staggerStep = intervalNanos == 0 || channels.isEmpty()
                    ? 0 : intervalNanos / channels.size();
            for (Channel ch : channels) {
                ch.pipeline().get(RequestLoop.class).start(ch, stagger);
                stagger += staggerStep;
            }
            Thread.sleep(TimeUnit.SECONDS.toMillis(durationSec));
            long steadyNanos = System.nanoTime() - steadyStart;
            // Read the counters at the end of the measured window rather than after the drain, so
            // the 200 ms quiet period below is not counted as allocation-free time.
            Counters delta = Counters.snapshot().since(before);
            String poolAfter = Prealloc.poolState();
            for (Channel ch : channels) {
                ch.pipeline().get(RequestLoop.class).stop();
            }
            // Let anything in flight land before reading the histogram.
            Thread.sleep(200);

            if (prealloc) {
                for (Histogram h : perLoop.values()) {
                    latency.add(h);
                }
            }
            double seconds = steadyNanos / 1e9;
            double achieved = requests.get() / seconds;
            // Percentiles from an open-loop run only mean anything if the offered rate was actually
            // delivered. If the system could not keep up, the histogram holds the backlog, and
            // quoting that as latency is the same mistake as quoting closed-loop p50.
            String mode = rate == 0
                    ? "closed-loop:latency-is-queue-depth"
                    : achieved >= rate * 0.95
                        ? "open-loop:target-met"
                        : String.format("open-loop:TARGET-MISSED-%.0f%%:percentiles-invalid",
                                        100 * achieved / rate);
            System.out.printf(
                "STEADY durationS=%.1f requests=%d reqPerSec=%.0f targetPerSec=%d errors=%d "
                + "p50us=%d p99us=%d p999us=%d maxUs=%d mode=%s %s poolBefore=[%s] poolAfter=[%s]%n",
                seconds, requests.get(), achieved, rate, errors.get(),
                latency.getValueAtPercentile(50.0), latency.getValueAtPercentile(99.0),
                latency.getValueAtPercentile(99.9), latency.getMaxValue(), mode,
                delta.perRequest(requests.get()), poolBefore, poolAfter);
            // Where the client spent itself. The server prints its own on shutdown; the two are
            // reported separately because they are pinned to different cores and answer different
            // questions.
            System.out.printf("CLIENTCPU %s %s%n", delta, delta.perRequest(requests.get()));
            System.out.flush();
        } finally {
            for (Channel ch : channels) {
                ch.close();
            }
            group.shutdownGracefully();
        }
    }

    /**
     * Drives one connection, in one of two modes.
     *
     * <p><b>Closed loop</b> (no {@code --rate}): one request in flight, send the next as soon as the
     * previous returns. This saturates the system and measures maximum throughput. Its latency
     * figures are <em>not</em> service times -- with N connections all pushing, Little's Law fixes
     * p50 at roughly N/throughput regardless of how fast the stack is, so what they really report is
     * the queue depth the operator chose. At 10k connections that is tens of milliseconds and means
     * nothing on its own.
     *
     * <p><b>Open loop</b> ({@code --rate}): each connection sends on a fixed schedule derived from
     * the target rate, independently of whether earlier requests have come back. Latency is measured
     * from the time a request was <em>due</em> to be sent rather than when it actually went out,
     * which is what stops a stalled system from hiding its own delay -- the coordinated omission
     * problem. These percentiles are meaningful, provided the achieved rate actually matched the
     * target; the caller checks that and says so when it did not.
     */
    static final class RequestLoop extends ChannelInboundHandlerAdapter {
        private final Histogram shared;
        private final Map<EventExecutor, Histogram> perLoop;   // null unless --prealloc
        private final AtomicLong requests;
        private final AtomicLong errors;
        private final int payload;
        private final long intervalNanos;   // 0 => closed loop
        /** The one frame every connection sends, or null in the default allocating path. */
        private final ByteBuf frame;
        private volatile boolean running;
        private long closedLoopSentAt;
        /** Intended send times, FIFO: the server echoes in order on one connection. */
        private final ArrayDeque<Long> pending;
        /**
         * The same thing without the boxing. {@code ArrayDeque<Long>} boxes a nanotime value on
         * every open-loop request, and a nanotime is far outside the {@code Long} cache, so it is a
         * guaranteed heap allocation per request on the axis being measured.
         */
        private final long[] dueRing;
        private int dueHead;
        private int dueTail;
        private Histogram mine;
        private long nextDue;
        private ScheduledFuture<?> ticker;

        RequestLoop(Histogram shared, Map<EventExecutor, Histogram> perLoop, AtomicLong requests,
                    AtomicLong errors, int payload, long intervalNanos, ByteBuf frame) {
            this.shared = shared;
            this.perLoop = perLoop;
            this.requests = requests;
            this.errors = errors;
            this.payload = payload;
            this.intervalNanos = intervalNanos;
            this.frame = frame;
            this.pending = frame == null ? new ArrayDeque<Long>() : null;
            this.dueRing = frame == null || intervalNanos == 0 ? null : new long[1024];
        }

        void start(Channel ch, long staggerNanos) {
            if (perLoop != null) {
                mine = perLoop.get(ch.eventLoop());
                if (mine == null) {
                    throw new IllegalStateException("no histogram for event loop " + ch.eventLoop());
                }
            }
            running = true;
            if (intervalNanos == 0) {
                ch.eventLoop().execute(() -> send(ch));
            } else {
                nextDue = System.nanoTime() + staggerNanos;
                ticker = ch.eventLoop().scheduleAtFixedRate(
                        () -> tick(ch), staggerNanos, intervalNanos, TimeUnit.NANOSECONDS);
            }
        }

        void stop() {
            running = false;
            if (ticker != null) {
                ticker.cancel(false);
            }
        }

        private void send(Channel ch) {
            if (!running || !ch.isActive()) {
                return;
            }
            if (intervalNanos == 0) {
                closedLoopSentAt = System.nanoTime();
            }
            if (frame == null) {
                ch.writeAndFlush(ch.alloc().buffer(payload).writeZero(payload));
            } else {
                // retainedSlice on a pooled buffer goes to PooledSlicedByteBuf.newInstance, which
                // comes off a Recycler: no allocation, and no memset of the payload either. The
                // master frame is retained for the process lifetime and each slice releases one
                // reference when the write completes.
                ch.writeAndFlush(frame.retainedSlice(), ch.voidPromise());
            }
        }

        private void tick(Channel ch) {
            if (!running || !ch.isActive()) {
                return;
            }
            // Record the time this request was DUE, not now. If the event loop is behind, that
            // lateness belongs in the latency figure rather than being quietly discarded.
            long due = nextDue;
            nextDue += intervalNanos;
            if (dueRing == null) {
                pending.addLast(due);
            } else {
                dueRing[dueTail & (dueRing.length - 1)] = due;
                dueTail++;
                if (dueTail - dueHead > dueRing.length) {
                    // More than 1024 requests outstanding on one connection means the run is not
                    // measuring what it claims to; losing the oldest due time silently would flatter
                    // the percentiles.
                    throw new IllegalStateException("open-loop backlog exceeded " + dueRing.length
                            + " on one connection; the target rate is unachievable");
                }
            }
            send(ch);
        }

        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            ((ByteBuf) msg).release();
            long now = System.nanoTime();
            long from;
            if (intervalNanos == 0) {
                from = closedLoopSentAt;
            } else if (dueRing == null) {
                from = pending.isEmpty() ? now : pending.pollFirst();
            } else {
                from = dueHead == dueTail ? now : dueRing[dueHead++ & (dueRing.length - 1)];
            }
            long us = TimeUnit.NANOSECONDS.toMicros(now - from);
            if (mine != null) {
                // One histogram per event loop, so no lock and no cross-thread sharing. Merged once
                // at the end of the run.
                mine.recordValue(Math.max(1, us));
            } else {
                // The histogram is shared across event loop threads and is not thread safe; a lost
                // count here would quietly bias the percentiles, so take the lock.
                synchronized (shared) {
                    shared.recordValue(Math.max(1, us));
                }
            }
            requests.incrementAndGet();
            if (intervalNanos == 0) {
                send(ctx.channel());
            }
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            errors.incrementAndGet();
            ctx.close();
        }
    }

    // ------------------------------------------------------------------ wiring

    /**
     * Thread ids of the event loops, so allocation can be attributed to them.
     *
     * <p>Collected by running a task on each loop rather than by matching thread names: netty's
     * naming has changed across versions and a name-matching scheme that stopped matching would
     * report a confident zero.
     */
    private static long[] loopThreadIds(EventLoopGroup group) {
        List<Future<Long>> futures = new ArrayList<Future<Long>>();
        for (EventExecutor e : group) {
            futures.add(e.submit(() -> Thread.currentThread().getId()));
        }
        long[] ids = new long[futures.size()];
        for (int i = 0; i < ids.length; i++) {
            ids[i] = futures.get(i).syncUninterruptibly().getNow();
        }
        return ids;
    }

    /**
     * Sizes and runs the arena warm-up, or aborts saying why it cannot.
     *
     * <p>The default size is two buffers per connection, which is roughly what an echo holds live:
     * one accumulating on the read side and one queued on the write side. It is a starting point,
     * not a claim; {@code --warmup-mb} overrides it and the READY line reports what was actually
     * pinned so the choice is visible in every log.
     */
    private static String warmUp(Args a, EventLoopGroup group) {
        int payload = a.getInt("payload", -1);
        if (payload <= 0) {
            throw new IllegalStateException("--prealloc needs --payload so the warm-up allocates in "
                    + "the size class the run will use; got " + payload);
        }
        long mb = a.getLong("warmup-mb", -1);
        if (mb < 0) {
            int conns = a.getInt("connections", -1);
            if (conns <= 0) {
                throw new IllegalStateException("--prealloc needs --warmup-mb, or --connections to "
                        + "derive it from. Refusing to run a cell labelled prealloc with an unwarmed "
                        + "arena.");
            }
            mb = Math.max(16L, 2L * conns * (payload + 4) / (1024 * 1024));
        }
        return Prealloc.warmArenas(group, mb * 1024 * 1024, payload + 4);
    }

    /**
     * Turns on {@code IORING_OP_SEND_ZC} above a byte threshold, for io_uring only.
     *
     * <p>Netty exposes this as {@code IO_URING_WRITE_ZERO_COPY_THRESHOLD} and defaults it to -1,
     * meaning off, so every write copies. Zero-copy send is the one io_uring feature with no epoll
     * equivalent in netty: matching it would need {@code MSG_ZEROCOPY}, which netty's epoll
     * transport does not use. That makes it the only lever here that could let io_uring win
     * outright rather than merely catch up, and it can only pay above the payload size where the
     * avoided copy outweighs the page pinning and the extra completion notification it costs.
     *
     * <p>Set by reflection because the option class lives in the io_uring artifact: naming it
     * directly would make this class fail to load when running the epoll or NIO cells on a machine
     * that has no io_uring jar. Every failure path aborts rather than leaving the option quietly
     * unset, on the same rule as the transport selection: a cell labelled zero-copy that silently
     * was not would be worse than no cell at all.
     */
    /**
     * {@code --rcvbuf-max} bounds the adaptive receive-buffer guess, {@code --sndbuf} fixes
     * SO_SNDBUF. Both exist to discriminate between two candidate mechanisms for the size cliff:
     *
     * <ul>
     *   <li>A completion-based transport commits its receive buffer at submit time, so it holds one
     *       per read in flight. Capping the guess caps that footprint; if the cliff is the pool
     *       thrashing under 2x footprint, the cap should close most of the gap.</li>
     *   <li>Netty's io_uring write path has no write spin loop: getWriteSpinCount() is consumed
     *       nowhere in transport-classes-io_uring, so a partial write costs a POLL_ADD round trip
     *       where epoll retries with another cheap write() up to 16 times. Partial writes per
     *       message scale with payload against a fixed sndbuf, which also predicts a widening
     *       deficit. A larger SO_SNDBUF means fewer partial writes; if the cliff follows sndbuf on
     *       io_uring while epoll stays flat, the write path is the mechanism.</li>
     * </ul>
     *
     * <p><b>Why {@code --prealloc} does not size the receive buffer to the payload.</b> The obvious
     * pre-allocation move is a {@code FixedRecvByteBufAllocator} of {@code payload + 4}, and it is
     * available as {@code --fixed-rcvbuf}. It is not what {@code --prealloc} does, because the
     * receive buffer ceiling is already the established mechanism for the size cliff -- 16 KB, 64 KB
     * and 512 KB give 13,586 / 17,257 / 23,458 req/s at a 64 KB payload -- so folding it into the
     * pre-allocation flag would confound "removing the harness's allocation closed the gap" with
     * "raising the read size closed the gap", and the second is already known to be true. What
     * {@code --prealloc} does instead is fix the receive buffer at the adaptive allocator's own
     * default ceiling, 64 KB, which leaves reads per message exactly where the default put them and
     * only removes the run-to-run variation from the adaptive guess moving mid-run.
     *
     * @return a description of the receive allocator actually installed, for the startup line
     */
    private static String applyBufferTuning(AbstractBootstrap<?, ?> b, Args a, boolean prealloc) {
        int sndbuf = a.getInt("sndbuf", 0);
        int rcvbufMax = a.getInt("rcvbuf-max", 0);
        int fixedRcvbuf = a.getInt("fixed-rcvbuf", 0);
        boolean child = b instanceof ServerBootstrap;
        if (sndbuf > 0) {
            if (child) {
                ((ServerBootstrap) b).childOption(ChannelOption.SO_SNDBUF, sndbuf);
            } else {
                b.option(ChannelOption.SO_SNDBUF, sndbuf);
            }
        }
        if (rcvbufMax > 0 && fixedRcvbuf > 0) {
            throw new IllegalArgumentException("--rcvbuf-max and --fixed-rcvbuf are two different "
                    + "receive allocators; pick one");
        }
        RecvByteBufAllocator recv;
        String description;
        if (rcvbufMax > 0) {
            recv = new AdaptiveRecvByteBufAllocator(64, Math.min(2048, rcvbufMax), rcvbufMax);
            description = "recvAlloc=adaptive-bounded:" + rcvbufMax;
        } else if (fixedRcvbuf > 0) {
            recv = new FixedRecvByteBufAllocator(fixedRcvbuf);
            description = "recvAlloc=fixed:" + fixedRcvbuf;
        } else if (prealloc) {
            // AdaptiveRecvByteBufAllocator's own default maximum. Same read size the default path
            // converges to, so read count per message is unchanged; see the note above.
            int size = Math.min(a.getInt("payload", 65536) + 4, 65536);
            recv = new FixedRecvByteBufAllocator(size);
            description = "recvAlloc=fixed:" + size;
        } else {
            return "recvAlloc=adaptive-default";
        }
        if (child) {
            ((ServerBootstrap) b).childOption(ChannelOption.RCVBUF_ALLOCATOR, recv);
        } else {
            b.option(ChannelOption.RCVBUF_ALLOCATOR, recv);
        }
        return description;
    }

    private static void applyZeroCopy(AbstractBootstrap<?, ?> b, Transports t, Args a) {
        int threshold = a.getInt("zc-threshold", -1);
        if (threshold < 0) {
            return;
        }
        if (t != Transports.IO_URING) {
            throw new IllegalArgumentException("--zc-threshold needs --transport=io_uring, got " + t);
        }
        try {
            Class<?> optionClass = Class.forName("io.netty.channel.uring.IoUringChannelOption");
            @SuppressWarnings("unchecked")
            ChannelOption<Integer> option = (ChannelOption<Integer>)
                    optionClass.getField("IO_URING_WRITE_ZERO_COPY_THRESHOLD").get(null);
            if (b instanceof ServerBootstrap) {
                // The server's writes happen on the accepted children, not on the listening socket.
                ((ServerBootstrap) b).childOption(option, threshold);
            } else {
                b.option(option, threshold);
            }
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("cannot set IO_URING_WRITE_ZERO_COPY_THRESHOLD", e);
        }
    }
}
