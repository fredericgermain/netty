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

import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFuture;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.MultiThreadIoEventLoopGroup;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.LengthFieldPrepender;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslHandler;
import io.netty.util.concurrent.Future;
import org.HdrHistogram.Histogram;

import java.net.InetSocketAddress;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
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
    }

    // ------------------------------------------------------------------ server

    private static void server(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        SslContext ssl = Tls.serverContext(a.get("tls", "none"));

        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, t.ioHandler());
        EventLoopGroup worker = new MultiThreadIoEventLoopGroup(a.threads(), t.ioHandler());
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
                            ch.pipeline()
                              .addLast(new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 4))
                              .addLast(new LengthFieldPrepender(4))
                              .addLast(new EchoHandler());
                        }
                    });
            Channel ch = b.bind(new InetSocketAddress(a.get("host", "0.0.0.0"), a.getInt("port", 9999)))
                          .sync().channel();
            System.out.println("READY transport=" + t + " tls=" + a.get("tls", "none")
                    + " backlog=" + a.getInt("backlog", 8192) + " threads=" + a.threads());
            System.out.flush();
            ch.closeFuture().sync();
        } finally {
            boss.shutdownGracefully();
            worker.shutdownGracefully();
        }
    }

    /** Echoes the frame straight back. Nothing allocated, nothing copied. */
    private static final class EchoHandler extends ChannelInboundHandlerAdapter {
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            ctx.writeAndFlush(msg);
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }
    }

    // ------------------------------------------------------------------ client

    private static void client(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        SslContext ssl = Tls.clientContext(a.get("tls", "none"));

        int connections = a.getInt("connections", 10000);
        int durationSec = a.getInt("duration", 15);
        int payload = a.getInt("payload", 1024);
        // Total requests/s across all connections. Absent => closed loop: saturate and report
        // throughput only, because closed-loop latency is queue depth rather than service time.
        int rate = a.getInt("rate", 0);
        long intervalNanos = rate == 0 ? 0 : (long) (1e9 * connections / rate);
        String host = a.get("host", "127.0.0.1");
        int port = a.getInt("port", 9999);

        EventLoopGroup group = new MultiThreadIoEventLoopGroup(a.threads(), t.ioHandler());
        // Recorded across every connection. Values are microseconds; three significant digits is
        // plenty for percentiles and keeps the histogram small enough to be free.
        Histogram latency = new Histogram(1, TimeUnit.SECONDS.toMicros(60), 3);
        AtomicLong requests = new AtomicLong();
        AtomicLong errors = new AtomicLong();
        List<Channel> channels = new ArrayList<>(connections);

        try {
            Bootstrap b = new Bootstrap()
                    .group(group)
                    .channel(t.clientChannel())
                    .option(ChannelOption.TCP_NODELAY, true)
                    .option(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
                    .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 30000);

            // ---------------- ramp
            CountDownLatch ready = new CountDownLatch(connections);
            long rampStart = System.nanoTime();
            List<ChannelFuture> pending = new ArrayList<>(connections);
            for (int i = 0; i < connections; i++) {
                Bootstrap bb = b.clone().handler(new ChannelInitializer<Channel>() {
                    @Override protected void initChannel(Channel ch) {
                        if (ssl != null) {
                            SslHandler h = ssl.newHandler(ch.alloc(), host, port);
                            ch.pipeline().addLast(h);
                            // Count the connection ready only once TLS is up, so the ramp number
                            // is connections-and-handshakes rather than TCP connects.
                            h.handshakeFuture().addListener((Future<Channel> f) -> {
                                if (f.isSuccess()) {
                                    ready.countDown();
                                } else {
                                    errors.incrementAndGet();
                                    ready.countDown();
                                }
                            });
                        }
                        ch.pipeline()
                          .addLast(new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 4))
                          .addLast(new LengthFieldPrepender(4))
                          .addLast(new RequestLoop(latency, requests, errors, payload, intervalNanos));
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

            System.out.printf("RAMP  connections=%d established=%d errors=%d wallMs=%d connPerSec=%.0f%n",
                    connections, channels.size(), errors.get(),
                    TimeUnit.NANOSECONDS.toMillis(rampNanos),
                    channels.size() / (rampNanos / 1e9));
            System.out.flush();

            // ---------------- steady
            latency.reset();
            requests.set(0);
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
            for (Channel ch : channels) {
                ch.pipeline().get(RequestLoop.class).stop();
            }
            // Let anything in flight land before reading the histogram.
            Thread.sleep(200);

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
                + "p50us=%d p99us=%d p999us=%d maxUs=%d mode=%s%n",
                seconds, requests.get(), achieved, rate, errors.get(),
                latency.getValueAtPercentile(50.0), latency.getValueAtPercentile(99.0),
                latency.getValueAtPercentile(99.9), latency.getMaxValue(), mode);
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
        private final Histogram latency;
        private final AtomicLong requests;
        private final AtomicLong errors;
        private final int payload;
        private final long intervalNanos;   // 0 => closed loop
        private volatile boolean running;
        private long closedLoopSentAt;
        /** Intended send times, FIFO: the server echoes in order on one connection. */
        private final ArrayDeque<Long> pending = new ArrayDeque<>();
        private long nextDue;
        private ScheduledFuture<?> ticker;

        RequestLoop(Histogram latency, AtomicLong requests, AtomicLong errors, int payload,
                    long intervalNanos) {
            this.latency = latency;
            this.requests = requests;
            this.errors = errors;
            this.payload = payload;
            this.intervalNanos = intervalNanos;
        }

        void start(Channel ch, long staggerNanos) {
            running = true;
            if (intervalNanos == 0) {
                ch.eventLoop().execute(() -> sendClosed(ch));
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

        private void sendClosed(Channel ch) {
            if (!running || !ch.isActive()) {
                return;
            }
            closedLoopSentAt = System.nanoTime();
            ch.writeAndFlush(ch.alloc().buffer(payload).writeZero(payload));
        }

        private void tick(Channel ch) {
            if (!running || !ch.isActive()) {
                return;
            }
            // Record the time this request was DUE, not now. If the event loop is behind, that
            // lateness belongs in the latency figure rather than being quietly discarded.
            long due = nextDue;
            nextDue += intervalNanos;
            pending.addLast(due);
            ch.writeAndFlush(ch.alloc().buffer(payload).writeZero(payload));
        }

        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            ((ByteBuf) msg).release();
            long now = System.nanoTime();
            long from = intervalNanos == 0 ? closedLoopSentAt
                                           : (pending.isEmpty() ? now : pending.pollFirst());
            long us = TimeUnit.NANOSECONDS.toMicros(now - from);
            // The histogram is shared across event loop threads and is not thread safe; a lost
            // count here would quietly bias the percentiles, so take the lock.
            synchronized (latency) {
                latency.recordValue(Math.max(1, us));
            }
            requests.incrementAndGet();
            if (intervalNanos == 0) {
                sendClosed(ctx.channel());
            }
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            errors.incrementAndGet();
            ctx.close();
        }
    }
}
