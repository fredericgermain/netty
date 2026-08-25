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
import io.netty.channel.epoll.EpollIoHandler;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.epoll.EpollSocketChannel;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.channel.uring.IoUring;
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
        @Override public IoHandlerFactory ioHandler(int ringSize) { return NioIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return NioServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return NioSocketChannel.class; }
        @Override public void ensureAvailable() { /* always */ }
    },
    EPOLL {
        @Override public IoHandlerFactory ioHandler(int ringSize) { return EpollIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return EpollServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return EpollSocketChannel.class; }
        @Override public void ensureAvailable() {
            if (!Epoll.isAvailable()) {
                throw new IllegalStateException("epoll is not available", Epoll.unavailabilityCause());
            }
        }
    },
    IO_URING {
        @Override public IoHandlerFactory ioHandler(int ringSize) {
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
            return IoUringIoHandler.newFactory(cfg);
        }
        @Override public Class<? extends ServerChannel> serverChannel() { return IoUringServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return IoUringSocketChannel.class; }
        @Override public void ensureAvailable() {
            if (!IoUring.isAvailable()) {
                throw new IllegalStateException("io_uring is not available", IoUring.unavailabilityCause());
            }
        }
    };

    /** @param ringSize io_uring submission ring entries; ignored by the other transports. */
    public abstract IoHandlerFactory ioHandler(int ringSize);
    public abstract Class<? extends ServerChannel> serverChannel();
    public abstract Class<? extends Channel> clientChannel();
    public abstract void ensureAvailable();

    public static Transports parse(String s) {
        return valueOf(s.toUpperCase().replace('-', '_'));
    }
}
