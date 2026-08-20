/*
 * Copyright 2017 The Netty Project
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
package io.netty.microbench.handler.ssl;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import io.netty.channel.ChannelHandler;
import io.netty.handler.codec.ByteToMessageDecoder;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.SslHandler;
import io.netty.handler.ssl.SslProvider;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.microbench.channel.EmbeddedChannelWriteAccumulatingHandlerContext;
import io.netty.microbench.util.AbstractMicrobenchmark;
import io.netty.util.ReferenceCountUtil;
import org.openjdk.jmh.annotations.Param;

import java.io.InputStream;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLException;

import static io.netty.handler.codec.ByteToMessageDecoder.COMPOSITE_CUMULATOR;

public class AbstractSslHandlerBenchmark extends AbstractMicrobenchmark {
    private static final String PROTOCOL_TLS_V1_2 = "TLSv1.2";
    private static final String PROTOCOL_TLS_V1_3 = "TLSv1.3";

    /**
     * TLS 1.3 renamed its cipher suites and shares none with TLS 1.2, so the suite alone says which
     * protocol to enable. That keeps the protocol out of the {@code @Param} set: crossing protocol
     * with cipher would generate combinations that cannot handshake, and JMH has no way to skip
     * them other than failing the run.
     */
    private static String protocolOf(String cipher) {
        return cipher.startsWith("TLS_AES_") || cipher.startsWith("TLS_CHACHA20_")
                ? PROTOCOL_TLS_V1_3 : PROTOCOL_TLS_V1_2;
    }

    public enum SslEngineProvider {
        JDK {
            @Override
            SslProvider sslProvider() {
                return SslProvider.JDK;
            }
        },
        OPENSSL {
            @Override
            SslProvider sslProvider() {
                return SslProvider.OPENSSL;
            }
        },
        OPENSSL_REFCNT {
            @Override
            SslProvider sslProvider() {
                return SslProvider.OPENSSL_REFCNT;
            }
        };
        // Built lazily, not in field initialisers. Enum constants are all constructed in <clinit>,
        // so eager fields make every constant's context -- including OPENSSL's, which calls
        // OpenSsl.ensureAvailability() -- a prerequisite for using any of them. That makes the
        // pure-JDK benchmarks fail on any machine where tcnative is unavailable, which is exactly
        // where the JDK provider is the one you want to measure.
        private SslContext clientContext;
        private SslContext serverContext;

        private synchronized SslContext clientContext() {
            if (clientContext == null) {
                clientContext = newClientContext();
            }
            return clientContext;
        }

        private synchronized SslContext serverContext() {
            if (serverContext == null) {
                serverContext = newServerContext();
            }
            return serverContext;
        }

        private SslContext newClientContext() {
            try {
                return SslContextBuilder.forClient()
                        .sslProvider(sslProvider())
                        .trustManager(InsecureTrustManagerFactory.INSTANCE)
                        .build();
            } catch (SSLException e) {
                throw new IllegalStateException(e);
            }
        }

        private SslContext newServerContext() {
            // Read the material as streams rather than resolving it to a File. URL.getFile() on a
            // classpath entry inside a jar yields "file:/....jar!/io/netty/...", which is not a
            // filesystem path, so the File overload works only from an exploded target/classes and
            // fails for every SSL benchmark in the shaded benchmark-jar.
            try (InputStream crt = getClass().getResourceAsStream("test.crt");
                 InputStream key = getClass().getResourceAsStream("test_unencrypted.pem")) {
                if (crt == null || key == null) {
                    throw new IllegalStateException("missing test.crt or test_unencrypted.pem on the classpath");
                }
                return SslContextBuilder.forServer(crt, key)
                        .sslProvider(sslProvider())
                        .build();
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }

        SslHandler newClientHandler(ByteBufAllocator allocator, String cipher) {
            SslHandler handler = clientContext().newHandler(allocator);
            configureEngine(handler.engine(), cipher);
            return handler;
        }

        SslHandler newServerHandler(ByteBufAllocator allocator, String cipher) {
            SslHandler handler = serverContext().newHandler(allocator);
            configureEngine(handler.engine(), cipher);
            return handler;
        }

        abstract SslProvider sslProvider();

        static SSLEngine configureEngine(SSLEngine engine, String cipher) {
            engine.setEnabledProtocols(new String[]{ protocolOf(cipher) });
            engine.setEnabledCipherSuites(new String[]{ cipher });
            return engine;
        }
    }

    @Param
    public SslEngineProvider sslProvider;

    // Includes cipher required by HTTP/2
    @Param({ "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
             "TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384" })
    public String cipher;

    protected SslHandler clientSslHandler;
    protected SslHandler serverSslHandler;
    protected EmbeddedChannelWriteAccumulatingHandlerContext clientCtx;
    protected EmbeddedChannelWriteAccumulatingHandlerContext serverCtx;

    protected final void initSslHandlers(ByteBufAllocator allocator) {
        clientSslHandler = newClientHandler(allocator);
        serverSslHandler = newServerHandler(allocator);
        clientCtx = new SslThroughputBenchmarkHandlerContext(allocator, clientSslHandler, COMPOSITE_CUMULATOR);
        serverCtx = new SslThroughputBenchmarkHandlerContext(allocator, serverSslHandler, COMPOSITE_CUMULATOR);
    }

    protected final void destroySslHandlers() {
        try {
            if (clientSslHandler != null) {
                ReferenceCountUtil.release(clientSslHandler.engine());
            }
        } finally {
            if (serverSslHandler != null) {
                ReferenceCountUtil.release(serverSslHandler.engine());
            }
        }
    }

    protected final void doHandshake() throws Exception {
        serverSslHandler.handlerAdded(serverCtx);
        clientSslHandler.handlerAdded(clientCtx);
        do {
            ByteBuf clientCumulation = clientCtx.cumulation();
            if (clientCumulation != null) {
                serverSslHandler.channelRead(serverCtx, clientCumulation.retain());
                clientCtx.releaseCumulation();
            }
            ByteBuf serverCumulation = serverCtx.cumulation();
            if (serverCumulation != null) {
                clientSslHandler.channelRead(clientCtx, serverCumulation.retain());
                serverCtx.releaseCumulation();
            }
        } while (!clientSslHandler.handshakeFuture().isDone() || !serverSslHandler.handshakeFuture().isDone());
    }

    protected final SslHandler newClientHandler(ByteBufAllocator allocator) {
        return sslProvider.newClientHandler(allocator, cipher);
    }

    protected final SslHandler newServerHandler(ByteBufAllocator allocator) {
        return sslProvider.newServerHandler(allocator, cipher);
    }

    private static final class SslThroughputBenchmarkHandlerContext extends
            EmbeddedChannelWriteAccumulatingHandlerContext {
        SslThroughputBenchmarkHandlerContext(ByteBufAllocator alloc, ChannelHandler handler,
                                                    ByteToMessageDecoder.Cumulator writeCumulator) {
            super(alloc, handler, writeCumulator);
        }

        @Override
        protected void handleException(Throwable t) {
            handleUnexpectedException(t);
        }
    }

    public static void handleUnexpectedException(Throwable t) {
        if (t != null) {
            throw new IllegalStateException(t);
        }
    }
}
