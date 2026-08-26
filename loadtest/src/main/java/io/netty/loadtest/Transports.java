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

import io.netty.channel.Channel;
import io.netty.channel.IoHandlerFactory;
import io.netty.channel.ServerChannel;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollDatagramChannel;
import io.netty.channel.epoll.EpollIoHandler;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.epoll.EpollSocketChannel;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.channel.uring.IoUring;
import io.netty.channel.uring.IoUringBufferRingConfig;
import io.netty.channel.uring.IoUringDatagramChannel;
import io.netty.channel.uring.IoUringFixedBufferRingAllocator;
import io.netty.channel.uring.IoUringIoHandler;
import io.netty.channel.uring.IoUringIoHandlerConfig;
import io.netty.channel.uring.IoUringServerSocketChannel;
import io.netty.channel.uring.IoUringSocketChannel;

/**
 * Maps a transport name to the classes that implement it.
 *
 * <p>Every one of these aborts rather than falling back when the native transport is unavailable.
 * Netty's own default is to fall back to NIO, which for a benchmark is the worst possible
 * behaviour: it publishes NIO's number under epoll's label and nothing in the output says so.
 */
public enum Transports {
    NIO {
        @Override public IoHandlerFactory ioHandler(int ringSize, int bufferRingEntries, int bufferSize) { return NioIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return NioServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return NioSocketChannel.class; }
        @Override public Class<? extends Channel> datagramChannel() { return NioDatagramChannel.class; }
        // NioDatagramChannelConfig does not know SO_REUSEPORT: java.nio only exposes it as an
        // ExtendedSocketOption and netty's NIO datagram config never reads it. Setting it anyway
        // gets a "Unknown channel option" warning from Bootstrap and is then ignored, which is the
        // exact silent-fallback shape this harness refuses everywhere else, so it is declared here
        // and checked before the bind rather than discovered from a log line.
        @Override public boolean supportsReusePort() { return false; }
        @Override public void ensureAvailable() { /* always */ }
    },
    EPOLL {
        @Override public IoHandlerFactory ioHandler(int ringSize, int bufferRingEntries, int bufferSize) { return EpollIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return EpollServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return EpollSocketChannel.class; }
        @Override public Class<? extends Channel> datagramChannel() { return EpollDatagramChannel.class; }
        @Override public boolean supportsReusePort() { return true; }
        @Override public void ensureAvailable() {
            if (!Epoll.isAvailable()) {
                throw new IllegalStateException("epoll is not available", Epoll.unavailabilityCause());
            }
        }
    },
    IO_URING {
        @Override public IoHandlerFactory ioHandler(int ringSize, int bufferRingEntries, int bufferSize) {
            // Configurable, but do NOT expect it to matter much. A run that produced 578 req/s
            // against epoll's 168789 also logged "CompletionQueue overflow detected, consider
            // increasing size: 4096", and the ring looked like the cause. It was not: sweeping
            // 4096 / 16384 / 32768 at ten thousand connections gives 127590 / 127014 / 125817
            // req/s, which is no difference at all. That run was contending with a second load
            // test for the same port and cores, and the overflow warning was a symptom of the
            // contention rather than its cause.
            //
            // Left configurable because the knob is real and a different workload may need it, and
            // because a documented negative result is worth more than a knob nobody has swept.
            IoUringIoHandlerConfig cfg = new IoUringIoHandlerConfig();
            cfg.setRingSize(ringSize);
            cfg.setCqSize(ringSize * 2);

            // A provided buffer ring, and it is not the minor tuning knob it looks like.
            //
            // AbstractIoUringStreamChannel only reaches scheduleReadProviderBuffer(), the sole
            // place that sets IORING_RECV_MULTISHOT, when a buffer ring is configured. Without one
            // every read is a fresh one-shot SQE: prepare, submit, reap the completion, re-arm.
            // io.netty.iouring.recvMultiShotEnabled defaults to true but is inert on its own, and
            // IoUringIoHandlerConfig leaves bufferRingConfigs null by default, so the out-of-the-box
            // configuration is the one that does the most work per read.
            //
            // That makes this the direct test of whether the plaintext deficit is netty's
            // completion path rather than the ring itself, which is where the ctimer profile
            // pointed: no dominant frame, just a long tail of handleFastPath, jctools accessors and
            // writeComplete0. Multishot removes most of those re-arms.
            if (bufferRingEntries > 0) {
                // batchSize must be set explicitly. The builder initialises it to -1 and then
                // validates it into 1..1024, so build() throws unless it is provided, unlike every
                // other optional field on the builder. Worth reporting upstream.
                cfg.setBufferRingConfig(IoUringBufferRingConfig.builder()
                        .bufferGroupId((short) 1)
                        .bufferRingSize((short) bufferRingEntries)
                        .batchSize(Math.min(bufferRingEntries, 256))
                        .allocator(new IoUringFixedBufferRingAllocator(bufferSize))
                        .build());
            }
            return IoUringIoHandler.newFactory(cfg);
        }
        @Override public Class<? extends ServerChannel> serverChannel() { return IoUringServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return IoUringSocketChannel.class; }
        @Override public Class<? extends Channel> datagramChannel() { return IoUringDatagramChannel.class; }
        @Override public boolean supportsReusePort() { return true; }
        @Override public void ensureAvailable() {
            if (!IoUring.isAvailable()) {
                throw new IllegalStateException("io_uring is not available", IoUring.unavailabilityCause());
            }
        }
    };

    /**
     * @param ringSize          io_uring submission ring entries; ignored by the other transports.
     * @param bufferRingEntries provided-buffer ring entries, or 0 to use none. Nonzero is what
     *                          arms multishot recv; see the note in {@code IO_URING}.
     * @param bufferSize        size of each provided buffer, when a buffer ring is in use.
     */
    public abstract IoHandlerFactory ioHandler(int ringSize, int bufferRingEntries, int bufferSize);
    public abstract Class<? extends ServerChannel> serverChannel();
    public abstract Class<? extends Channel> clientChannel();

    /** The UDP socket QUIC runs over. QUIC's codec is a handler on a datagram channel. */
    public abstract Class<? extends Channel> datagramChannel();

    /**
     * Whether several datagram channels of this transport can share one port.
     *
     * <p>A QUIC server has no accept: every connection arrives on the same UDP socket, so one
     * socket means one event loop thread handling every connection on the machine. The only way to
     * spread a QUIC server across cores is to bind the port several times with SO_REUSEPORT and let
     * the kernel's 4-tuple hash pick the socket. A transport that cannot do that is structurally
     * single-threaded for QUIC, which is a fact about the transport worth reporting rather than
     * hiding behind a lower number.
     */
    public abstract boolean supportsReusePort();

    public abstract void ensureAvailable();

    public static Transports parse(String s) {
        return valueOf(s.toUpperCase().replace('-', '_'));
    }
}
