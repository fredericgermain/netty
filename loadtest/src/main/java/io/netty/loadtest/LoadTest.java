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
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
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
                          .addLast(new RequestLoop(latency, requests, errors, payload));
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
            for (Channel ch : channels) {
                ch.pipeline().get(RequestLoop.class).start(ch);
            }
            Thread.sleep(TimeUnit.SECONDS.toMillis(durationSec));
            long steadyNanos = System.nanoTime() - steadyStart;
            for (Channel ch : channels) {
                ch.pipeline().get(RequestLoop.class).stop();
            }
            // Let anything in flight land before reading the histogram.
            Thread.sleep(200);

            double seconds = steadyNanos / 1e9;
            System.out.printf(
                "STEADY durationS=%.1f requests=%d reqPerSec=%.0f errors=%d "
                + "p50us=%d p99us=%d p999us=%d maxUs=%d%n",
                seconds, requests.get(), requests.get() / seconds, errors.get(),
                latency.getValueAtPercentile(50.0), latency.getValueAtPercentile(99.0),
                latency.getValueAtPercentile(99.9), latency.getMaxValue());
            System.out.flush();
        } finally {
            for (Channel ch : channels) {
                ch.close();
            }
            group.shutdownGracefully();
        }
    }

    /**
     * One request in flight per connection: write a frame, wait for it back, record the round trip,
     * write the next.
     */
    static final class RequestLoop extends ChannelInboundHandlerAdapter {
        private final Histogram latency;
        private final AtomicLong requests;
        private final AtomicLong errors;
        private final int payload;
        private volatile boolean running;
        private long sentAt;

        RequestLoop(Histogram latency, AtomicLong requests, AtomicLong errors, int payload) {
            this.latency = latency;
            this.requests = requests;
            this.errors = errors;
            this.payload = payload;
        }

        void start(Channel ch) {
            running = true;
            ch.eventLoop().execute(() -> send(ch));
        }

        void stop() {
            running = false;
        }

        private void send(Channel ch) {
            if (!running || !ch.isActive()) {
                return;
            }
            ByteBuf buf = ch.alloc().buffer(payload).writeZero(payload);
            sentAt = System.nanoTime();
            ch.writeAndFlush(buf);
        }

        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            ((ByteBuf) msg).release();
            long us = TimeUnit.NANOSECONDS.toMicros(System.nanoTime() - sentAt);
            // Histogram is not thread safe, but each connection is pinned to one event loop thread
            // and recordValue on a shared instance from several threads can lose counts. Synchronise
            // on it: at these rates the contention is far cheaper than getting the percentiles wrong.
            synchronized (latency) {
                latency.recordValue(Math.max(1, us));
            }
            requests.incrementAndGet();
            send(ctx.channel());
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            errors.incrementAndGet();
            ctx.close();
        }
    }
}
