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
import io.netty.buffer.ByteBuf;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFuture;
import io.netty.channel.ChannelHandler;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.FixedRecvByteBufAllocator;
import io.netty.channel.MultiThreadIoEventLoopGroup;
import io.netty.channel.unix.UnixChannelOption;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.LengthFieldPrepender;
import io.netty.handler.codec.quic.EpollQuicUtils;
import io.netty.handler.codec.quic.InsecureQuicTokenHandler;
import io.netty.handler.codec.quic.Quic;
import io.netty.handler.codec.quic.QuicChannel;
import io.netty.handler.codec.quic.QuicChannelBootstrap;
import io.netty.handler.codec.quic.QuicChannelOption;
import io.netty.handler.codec.quic.QuicClientCodecBuilder;
import io.netty.handler.codec.quic.QuicCodecBuilder;
import io.netty.handler.codec.quic.QuicCongestionControlAlgorithm;
import io.netty.handler.codec.quic.QuicServerCodecBuilder;
import io.netty.handler.codec.quic.QuicSslContext;
import io.netty.handler.codec.quic.QuicSslContextBuilder;
import io.netty.handler.codec.quic.QuicStreamChannel;
import io.netty.handler.codec.quic.QuicStreamType;
import io.netty.handler.codec.quic.SegmentedDatagramPacketAllocator;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.util.concurrent.EventExecutor;
import io.netty.util.concurrent.Future;
import org.HdrHistogram.Histogram;

import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The same two phases as {@link LoadTest}, over QUIC instead of TCP.
 *
 * <p>It exists because everything else on this branch measures a TCP byte stream, and the
 * conclusion that branch reached -- that the transports differ in how many reads they spend per
 * message -- is a statement about draining a stream socket. QUIC is the obvious place to find out
 * whether that framing generalises: it is UDP, congestion control and loss recovery live in
 * userspace inside quiche, TLS 1.3 is not optional, and streams are multiplexed over one
 * connection.
 *
 * <p>The phases, the {@code RAMP} / {@code STEADY} / {@code CLIENTCPU} / {@code SERVERCPU} lines
 * and the {@link LoadTest.RequestLoop} that drives them are shared with the TCP path rather than
 * reimplemented, so a QUIC table and a TCP table can be read side by side. The wire protocol on a
 * QUIC stream is the same 4-byte big-endian length prefix, because a QUIC stream is a byte stream
 * and needs framing for exactly the same reason TCP does.
 *
 * <h2>Three shape differences that are not tuning knobs</h2>
 *
 * <p><b>A QUIC server has no accept.</b> Every connection arrives as datagrams on one UDP socket,
 * so a single-socket server is a single-threaded server no matter how many event loops exist. The
 * only fix is SO_REUSEPORT: bind the port several times and let the kernel's 4-tuple hash pick the
 * socket. {@code --quic-server-sockets} does that. NIO cannot ({@link Transports#supportsReusePort}),
 * so a NIO QUIC server is structurally capped at one core and this class refuses to pretend
 * otherwise.
 *
 * <p><b>No {@link io.netty.handler.codec.quic.QuicCodecDispatcher} is used with SO_REUSEPORT.</b>
 * The dispatcher exists to re-route a packet the kernel delivered to the wrong socket, which
 * happens when a client migrates. Migration is disabled here ({@code activeMigration(false)}) and
 * every client socket stays bound for the life of the run, so the kernel's hash over
 * (saddr, sport, daddr, dport) sends every packet of a connection to the same server socket
 * throughout. Leaving the dispatcher out avoids its cross-event-loop {@code fireChannelRead}.
 *
 * <p><b>The client uses one UDP socket per QUIC connection.</b> QUIC could multiplex every
 * connection over one socket, but then every connection in the run would be serviced by one event
 * loop thread, and the comparison against N TCP sockets would really be a comparison against 1. One
 * socket per connection is the honest analogue and is what this class does.
 *
 * <h2>UDP buffers</h2>
 *
 * <p>{@code SO_RCVBUF} and {@code SO_SNDBUF} are set explicitly and reported back as the kernel
 * actually applied them, never inherited. An undersized UDP receive buffer does not surface as an
 * error: the kernel drops datagrams, quiche retransmits over the loss, and the run reports itself
 * as slow QUIC. {@code net.core.rmem_max} bounds what a plain {@code SO_RCVBUF} may ask for, so the
 * reported "actual" is the number that matters. Linux returns double what was requested, half being
 * its own bookkeeping allowance, so both numbers are printed.
 */
final class QuicLoad {

    /** The ALPN both ends require. A mismatch fails the handshake, which is the point of pinning it. */
    private static final String ALPN = "netty-loadtest";

    private QuicLoad() { }

    // ------------------------------------------------------------------ server

    /** Echoed frames, so the server's CPU deltas can be divided by something. */
    private static final AtomicLong SERVER_REQUESTS = new AtomicLong();

    static void server(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        requireQuic();
        final boolean prealloc = a.flag("prealloc");
        if (a.flag("jvm-tuned")) {
            Prealloc.requireTunedJvm();
        }

        int sockets = a.getInt("quic-server-sockets", a.threads());
        if (sockets < 1) {
            throw new IllegalArgumentException("--quic-server-sockets must be at least 1, got " + sockets);
        }
        if (sockets > 1 && !t.supportsReusePort()) {
            throw new IllegalStateException("--quic-server-sockets=" + sockets + " needs SO_REUSEPORT, "
                    + "which netty's " + t + " datagram channel does not support. Run this transport "
                    + "with --quic-server-sockets=1 and label it a one-socket cell, or pick a "
                    + "transport that can bind the port more than once.");
        }

        int payload = a.getInt("payload", 1024);
        QuicSslContext ssl = QuicSslContextBuilder
                .forServer(Tls.privateKey(), null, Tls.certificateChain())
                .applicationProtocols(ALPN)
                .build();

        EventLoopGroup group = new MultiThreadIoEventLoopGroup(a.threads(),
                t.ioHandler(a.getInt("ring-size", 16384), a.getInt("buffer-ring", 0),
                            a.getInt("buffer-ring-size", 2048)));
        LoadTest.trackLoops(group);
        List<Channel> bound = new ArrayList<Channel>(sockets);
        try {
            ChannelInitializer<QuicStreamChannel> streamInit = new ChannelInitializer<QuicStreamChannel>() {
                @Override protected void initChannel(QuicStreamChannel ch) {
                    addFraming(ch, prealloc);
                    ch.pipeline().addLast(new QuicEchoHandler(prealloc));
                }
            };
            QuicServerCodecBuilder codecBuilder = new QuicServerCodecBuilder()
                    .sslContext(ssl)
                    .tokenHandler(InsecureQuicTokenHandler.INSTANCE)
                    .handler(new SharableNoopHandler())
                    .streamHandler(streamInit);
            applyQuicConfig(codecBuilder, a);
            SegmentedDatagramPacketAllocator seg = segmentedAllocator(a, t);
            if (seg != null) {
                codecBuilder.option(QuicChannelOption.SEGMENTED_DATAGRAM_PACKET_ALLOCATOR, seg);
            }

            for (int i = 0; i < sockets; i++) {
                Bootstrap b = new Bootstrap()
                        .group(group)
                        .channel(t.datagramChannel())
                        .option(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
                        // A fresh codec per socket: it owns this socket's connection-id map and is
                        // not sharable, so one instance across sockets would cross-wire them.
                        .handler(codecBuilder.build());
                applyDatagramTuning(b, a);
                if (sockets > 1) {
                    b.option(UnixChannelOption.SO_REUSEPORT, true);
                }
                bound.add(b.bind(new InetSocketAddress(a.get("host", "0.0.0.0"),
                                                       a.getInt("port", 9999))).sync().channel());
            }

            group.next().scheduleAtFixedRate(() -> System.out.printf(
                    "SERVERCPU tMs=%d requests=%d %s %s%n",
                    System.currentTimeMillis(), SERVER_REQUESTS.get(), Counters.snapshot(),
                    Prealloc.poolState()),
                    2, 2, TimeUnit.SECONDS);

            System.out.println("READY protocol=quic transport=" + t + " tls=quic-tls13"
                    + " quicAvailable=" + Quic.isAvailable()
                    + " sockets=" + sockets + " reusePort=" + (sockets > 1)
                    + " threads=" + a.threads() + " payload=" + payload
                    + " prealloc=" + prealloc + " jvmTuned=" + a.flag("jvm-tuned")
                    + " " + quicConfigLine(a)
                    + " " + socketBufferLine(bound.get(0), a)
                    + " leakDetection=" + Prealloc.leakDetection()
                    + " " + Prealloc.poolState());
            System.out.flush();
            bound.get(0).closeFuture().sync();
        } finally {
            for (Channel ch : bound) {
                ch.close();
            }
            group.shutdownGracefully();
        }
    }

    /** Echoes the frame straight back on the stream it arrived on. */
    private static final class QuicEchoHandler extends ChannelInboundHandlerAdapter {
        private final boolean voidPromise;

        QuicEchoHandler(boolean voidPromise) {
            this.voidPromise = voidPromise;
        }

        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            SERVER_REQUESTS.incrementAndGet();
            if (voidPromise) {
                ctx.writeAndFlush(msg, ctx.voidPromise());
            } else {
                ctx.writeAndFlush(msg);
            }
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }
    }

    /** The server needs one connection-level handler instance across every connection. */
    private static final class SharableNoopHandler extends ChannelInboundHandlerAdapter {
        @Override public boolean isSharable() {
            return true;
        }
    }

    // ------------------------------------------------------------------ client

    static void client(Args a) throws Exception {
        Transports t = a.transport();
        t.ensureAvailable();
        requireQuic();
        final boolean prealloc = a.flag("prealloc");
        if (a.flag("jvm-tuned")) {
            Prealloc.requireTunedJvm();
        }

        final int connections = a.getInt("connections", 500);
        final int streamsPerConn = a.getInt("quic-streams", 1);
        if (streamsPerConn < 1) {
            throw new IllegalArgumentException("--quic-streams must be at least 1, got " + streamsPerConn);
        }
        final int durationSec = a.getInt("duration", 15);
        final int payload = a.getInt("payload", 1024);
        final int rate = a.getInt("rate", 0);
        final int loops = connections * streamsPerConn;
        final long intervalNanos = rate == 0 ? 0 : (long) (1e9 * loops / rate);
        final String host = a.get("host", "127.0.0.1");
        final int port = a.getInt("port", 9999);

        QuicSslContext ssl = QuicSslContextBuilder.forClient()
                .trustManager(InsecureTrustManagerFactory.INSTANCE)
                .applicationProtocols(ALPN)
                .build();

        EventLoopGroup group = new MultiThreadIoEventLoopGroup(a.threads(),
                t.ioHandler(a.getInt("ring-size", 16384), a.getInt("buffer-ring", 0),
                            a.getInt("buffer-ring-size", 2048)));
        LoadTest.trackLoops(group);
        Histogram latency = new Histogram(1, TimeUnit.SECONDS.toMicros(60), 3);
        final Map<EventExecutor, Histogram> perLoop =
                prealloc ? new IdentityHashMap<EventExecutor, Histogram>() : null;
        if (prealloc) {
            for (EventExecutor e : group) {
                perLoop.put(e, new Histogram(1, TimeUnit.SECONDS.toMicros(60), 3));
            }
        }
        final AtomicLong requests = new AtomicLong();
        final AtomicLong errors = new AtomicLong();
        final ByteBuf frame = prealloc ? Prealloc.buildFrame(payload) : null;

        // Synchronized: these fill from every event loop at once during the ramp.
        final List<Channel> streams = Collections.synchronizedList(new ArrayList<Channel>(loops));
        final List<Channel> quicChannels =
                Collections.synchronizedList(new ArrayList<Channel>(connections));
        final List<Channel> udpSockets =
                Collections.synchronizedList(new ArrayList<Channel>(connections));

        final Histogram sharedLatency = latency;
        final ChannelInitializer<QuicStreamChannel> streamInit =
                new ChannelInitializer<QuicStreamChannel>() {
            @Override protected void initChannel(QuicStreamChannel ch) {
                addFraming(ch, prealloc);
                ch.pipeline().addLast(new LoadTest.RequestLoop(sharedLatency, perLoop, requests,
                        errors, payload, intervalNanos, frame));
            }
        };

        try {
            QuicClientCodecBuilder codecBuilder = new QuicClientCodecBuilder().sslContext(ssl);
            applyQuicConfig(codecBuilder, a);
            final SegmentedDatagramPacketAllocator seg = segmentedAllocator(a, t);

            final Bootstrap udp = new Bootstrap()
                    .group(group)
                    .channel(t.datagramChannel())
                    .option(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT);
            applyDatagramTuning(udp, a);

            System.out.println("CLIENTCFG protocol=quic transport=" + t + " tls=quic-tls13"
                    + " quicAvailable=" + Quic.isAvailable()
                    + " connections=" + connections + " streamsPerConn=" + streamsPerConn
                    + " payload=" + payload + " threads=" + a.threads() + " rate=" + rate
                    + " prealloc=" + prealloc + " jvmTuned=" + a.flag("jvm-tuned")
                    + " " + quicConfigLine(a)
                    + " leakDetection=" + Prealloc.leakDetection()
                    + " " + Prealloc.poolState());
            System.out.flush();

            // ---------------- ramp
            // Every stream counts the latch down exactly once, so it covers the whole chain
            // bind -> QUIC handshake -> stream open and a failure anywhere still releases it.
            final CountDownLatch ready = new CountDownLatch(loops);
            final InetSocketAddress remote = new InetSocketAddress(host, port);
            final InetSocketAddress localBind = new InetSocketAddress(host, 0);
            long rampStart = System.nanoTime();
            for (int i = 0; i < connections; i++) {
                final ChannelFuture bindFuture =
                        udp.clone().handler(codecBuilder.build()).bind(localBind);
                bindFuture.addListener(bf -> {
                    if (!bf.isSuccess()) {
                        errors.incrementAndGet();
                        countDown(ready, streamsPerConn);
                        return;
                    }
                    Channel socket = bindFuture.channel();
                    udpSockets.add(socket);
                    QuicChannelBootstrap qb = QuicChannel.newBootstrap(socket)
                            .handler(new ChannelInboundHandlerAdapter())
                            .streamHandler(new ChannelInboundHandlerAdapter())
                            .remoteAddress(remote);
                    if (seg != null) {
                        qb.option(QuicChannelOption.SEGMENTED_DATAGRAM_PACKET_ALLOCATOR, seg);
                    }
                    qb.connect().addListener((Future<QuicChannel> qf) -> {
                        if (!qf.isSuccess()) {
                            errors.incrementAndGet();
                            countDown(ready, streamsPerConn);
                            return;
                        }
                        QuicChannel qch = qf.getNow();
                        quicChannels.add(qch);
                        for (int s = 0; s < streamsPerConn; s++) {
                            qch.createStream(QuicStreamType.BIDIRECTIONAL, streamInit)
                               .addListener((Future<QuicStreamChannel> sf) -> {
                                   if (sf.isSuccess()) {
                                       streams.add(sf.getNow());
                                   } else {
                                       errors.incrementAndGet();
                                   }
                                   ready.countDown();
                               });
                        }
                    });
                });
            }
            if (!ready.await(180, TimeUnit.SECONDS)) {
                System.err.println("ramp did not complete within 180s; " + ready.getCount()
                        + " outstanding");
            }
            long rampNanos = System.nanoTime() - rampStart;

            LoadTest.ramp(connections, quicChannels.size(), errors.get(), rampNanos);
            System.out.printf("QUICRAMP streamsRequested=%d streamsOpen=%d streamsPerConn=%d %s%n",
                    loops, streams.size(), streamsPerConn,
                    udpSockets.isEmpty() ? "udpSockets=none" : socketBufferLine(udpSockets.get(0), a));
            System.out.flush();

            // ---------------- steady
            LoadTest.steady(new ArrayList<Channel>(streams), latency, perLoop, requests, errors,
                            durationSec, rate, intervalNanos);
        } finally {
            for (Channel ch : new ArrayList<Channel>(streams)) {
                ch.close();
            }
            for (Channel ch : new ArrayList<Channel>(quicChannels)) {
                ch.close();
            }
            for (Channel ch : new ArrayList<Channel>(udpSockets)) {
                ch.close();
            }
            group.shutdownGracefully();
        }
    }

    private static void countDown(CountDownLatch latch, int times) {
        for (int i = 0; i < times; i++) {
            latch.countDown();
        }
    }

    // ------------------------------------------------------------------ wiring

    /**
     * Aborts unless quiche is actually loaded.
     *
     * <p>The one failure this harness must never survive quietly. The released QUIC native artifact
     * does not load on Alpine at all, so a run that got past this point without it would be
     * publishing a number for a protocol it never spoke.
     */
    private static void requireQuic() {
        if (!Quic.isAvailable()) {
            throw new IllegalStateException("QUIC native library is not available; refusing to run "
                    + "a cell labelled quic", Quic.unavailabilityCause());
        }
        Quic.ensureAvailability();
    }

    /** The same 4-byte big-endian length prefix the TCP cells use, so the wire work is comparable. */
    private static void addFraming(Channel ch, boolean prealloc) {
        ch.pipeline().addLast(prealloc
                ? new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 0)
                : new LengthFieldBasedFrameDecoder(1 << 20, 0, 4, 0, 4));
        if (!prealloc) {
            ch.pipeline().addLast(new LengthFieldPrepender(4));
        }
    }

    /**
     * Transport parameters, identical on both peers.
     *
     * <p>Flow control is the one that can silently become the bottleneck. A QUIC stream stops
     * sending once it has consumed its credit and waits for a MAX_STREAM_DATA frame, so a window
     * sized near the payload turns every request into an extra round trip and the run reports that
     * as latency. The defaults here are far above one request in flight; they are printed in the
     * header so a window-bound cell can be spotted rather than argued about.
     *
     * <p>{@code maxSendUdpPayloadSize} is pinned rather than left to quiche, because it decides how
     * many datagrams a payload becomes and loopback would otherwise tempt a run into a datagram
     * size no real network path would carry. 1200 is the conservative internet-safe value and is
     * what a QUIC deployment actually sends.
     */
    private static void applyQuicConfig(QuicCodecBuilder<?> cfg, Args a) {
        long connWindow = a.getLong("quic-flow-mb", 16) * 1024 * 1024;
        long streamWindow = a.getLong("quic-stream-flow-mb", 4) * 1024 * 1024;
        cfg.maxIdleTimeout(a.getLong("quic-idle-ms", 30000), TimeUnit.MILLISECONDS);
        cfg.initialMaxData(connWindow);
        cfg.initialMaxStreamDataBidirectionalLocal(streamWindow);
        cfg.initialMaxStreamDataBidirectionalRemote(streamWindow);
        cfg.initialMaxStreamsBidirectional(a.getLong("quic-max-streams", 256));
        cfg.initialMaxStreamsUnidirectional(0);
        // Pinned off so the kernel's SO_REUSEPORT hash stays a valid router: a migrating client
        // would start arriving on a different server socket, whose codec has never seen the
        // connection id. See the class comment on why no dispatcher is installed.
        cfg.activeMigration(false);
        cfg.maxSendUdpPayloadSize(a.getLong("quic-mtu", 1200));
        cfg.congestionControlAlgorithm(congestionControl(a));
    }

    private static QuicCongestionControlAlgorithm congestionControl(Args a) {
        String cc = a.get("quic-cc", "cubic");
        switch (cc) {
            case "cubic": return QuicCongestionControlAlgorithm.CUBIC;
            case "reno": return QuicCongestionControlAlgorithm.RENO;
            default: throw new IllegalArgumentException("--quic-cc must be cubic or reno, got: " + cc);
        }
    }

    private static String quicConfigLine(Args a) {
        return "alpn=" + ALPN
                + " quicMtu=" + a.getLong("quic-mtu", 1200)
                + " quicCc=" + a.get("quic-cc", "cubic")
                + " connWindowMb=" + a.getLong("quic-flow-mb", 16)
                + " streamWindowMb=" + a.getLong("quic-stream-flow-mb", 4)
                + " idleMs=" + a.getLong("quic-idle-ms", 30000)
                + " gso=" + a.getInt("quic-gso", 0);
    }

    /**
     * UDP generic segmentation offload, or null when it was not asked for.
     *
     * <p>Netty only ships a segmented allocator for epoll, and the factory quietly returns
     * {@code NONE} on a kernel without {@code UDP_SEGMENT}, so both cases abort rather than leave a
     * cell labelled gso running without it.
     */
    private static SegmentedDatagramPacketAllocator segmentedAllocator(Args a, Transports t) {
        int gso = a.getInt("quic-gso", 0);
        if (gso <= 0) {
            return null;
        }
        if (t != Transports.EPOLL) {
            throw new IllegalArgumentException("--quic-gso needs --transport=epoll; netty only "
                    + "provides a segmented datagram allocator for epoll. Got " + t);
        }
        SegmentedDatagramPacketAllocator seg = EpollQuicUtils.newSegmentedAllocator(gso);
        if (seg == SegmentedDatagramPacketAllocator.NONE) {
            throw new IllegalStateException("--quic-gso=" + gso + " requested but this kernel does "
                    + "not support UDP_SEGMENT; refusing to run a cell labelled gso without it");
        }
        return seg;
    }

    /**
     * Sets the UDP socket buffers and the receive allocator deliberately rather than by default.
     *
     * <p>{@code --udp-rcvbuf} is the one that decides whether a QUIC result means anything: an
     * undersized receive buffer presents as "QUIC is slow" and not as an error, because the
     * kernel's drop is invisible to the application and quiche retransmits over it.
     *
     * <p>The receive allocator matters for a second, quieter reason. A datagram channel reads one
     * datagram into one buffer and the kernel discards whatever does not fit, so a receive size
     * below the peer's maximum datagram truncates packets rather than splitting them. It is sized
     * from {@code --quic-mtu} with room for headers.
     */
    private static void applyDatagramTuning(Bootstrap b, Args a) {
        int rcvbuf = a.getInt("udp-rcvbuf", 4 * 1024 * 1024);
        int sndbuf = a.getInt("udp-sndbuf", 1024 * 1024);
        if (rcvbuf > 0) {
            b.option(ChannelOption.SO_RCVBUF, rcvbuf);
        }
        if (sndbuf > 0) {
            b.option(ChannelOption.SO_SNDBUF, sndbuf);
        }
        b.option(ChannelOption.RCVBUF_ALLOCATOR, new FixedRecvByteBufAllocator(recvSize(a)));
    }

    private static int recvSize(Args a) {
        return a.getInt("udp-recv-size", (int) Math.max(2048, a.getLong("quic-mtu", 1200) + 512));
    }

    /**
     * What the kernel actually gave, next to what was asked for.
     *
     * <p>Linux reports back double the requested {@code SO_RCVBUF} -- half is its own bookkeeping
     * allowance -- and silently clamps the request to {@code net.core.rmem_max}. Printing only the
     * request would record a buffer the socket does not have.
     */
    private static String socketBufferLine(Channel ch, Args a) {
        Integer rcv = ch.config().getOption(ChannelOption.SO_RCVBUF);
        Integer snd = ch.config().getOption(ChannelOption.SO_SNDBUF);
        return "udpRcvbufAsked=" + a.getInt("udp-rcvbuf", 4 * 1024 * 1024)
                + " udpRcvbufActual=" + rcv
                + " udpSndbufAsked=" + a.getInt("udp-sndbuf", 1024 * 1024)
                + " udpSndbufActual=" + snd
                + " udpRecvSize=" + recvSize(a);
    }
}
