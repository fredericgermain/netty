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
        @Override public IoHandlerFactory ioHandler() { return NioIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return NioServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return NioSocketChannel.class; }
        @Override public void ensureAvailable() { /* always */ }
    },
    EPOLL {
        @Override public IoHandlerFactory ioHandler() { return EpollIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return EpollServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return EpollSocketChannel.class; }
        @Override public void ensureAvailable() {
            if (!Epoll.isAvailable()) {
                throw new IllegalStateException("epoll is not available", Epoll.unavailabilityCause());
            }
        }
    },
    IO_URING {
        @Override public IoHandlerFactory ioHandler() { return IoUringIoHandler.newFactory(); }
        @Override public Class<? extends ServerChannel> serverChannel() { return IoUringServerSocketChannel.class; }
        @Override public Class<? extends Channel> clientChannel() { return IoUringSocketChannel.class; }
        @Override public void ensureAvailable() {
            if (!IoUring.isAvailable()) {
                throw new IllegalStateException("io_uring is not available", IoUring.unavailabilityCause());
            }
        }
    };

    public abstract IoHandlerFactory ioHandler();
    public abstract Class<? extends ServerChannel> serverChannel();
    public abstract Class<? extends Channel> clientChannel();
    public abstract void ensureAvailable();

    public static Transports parse(String s) {
        return valueOf(s.toUpperCase().replace('-', '_'));
    }
}
