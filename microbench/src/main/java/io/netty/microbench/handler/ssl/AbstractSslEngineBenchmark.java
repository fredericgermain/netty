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

import io.netty.buffer.ByteBufAllocator;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.OpenSslContextOption;
import io.netty.handler.ssl.SslProvider;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.microbench.util.AbstractMicrobenchmark;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.internal.CleanableDirectBuffer;
import io.netty.util.internal.PlatformDependent;
import org.openjdk.jmh.annotations.Param;

import java.io.InputStream;
import java.nio.ByteBuffer;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLEngineResult;
import javax.net.ssl.SSLException;


public class AbstractSslEngineBenchmark extends AbstractMicrobenchmark {

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

        /**
         * The key exchange group, from {@code -Dnetty.bench.tls.groups=X25519} or similar.
         *
         * <p>Without this the TLS 1.2 and TLS 1.3 rows are not comparable, because each side picks
         * its own default and they differ: the JDK offers secp256r1 for TLS 1.2 and x25519 for TLS
         * 1.3, and the BoringSSL bundled in netty-tcnative has X25519MLKEM768 and X25519Kyber768
         * compiled in, so a TLS 1.3 handshake between two BoringSSL peers may be doing
         * post-quantum key exchange while the TLS 1.2 row does classical ECDHE. That is a real
         * difference worth measuring, but only once it is the thing being varied rather than an
         * uncontrolled side effect of the protocol version.
         *
         * <p>A system property rather than a {@code @Param} because the contexts are built once
         * per provider per JVM, which is the granularity a JMH fork gives you anyway. Pair it with
         * {@code -Djdk.tls.namedGroups} for the JDK provider, which has no equivalent option here.
         */
        private static String[] configuredGroups() {
            String groups = System.getProperty("netty.bench.tls.groups", "");
            return groups.isEmpty() ? null : groups.split(",");
        }

        private SslContext newClientContext() {
            try {
                SslContextBuilder b = SslContextBuilder.forClient()
                        .sslProvider(sslProvider())
                        .trustManager(InsecureTrustManagerFactory.INSTANCE);
                String[] groups = configuredGroups();
                if (groups != null && sslProvider() != SslProvider.JDK) {
                    b.option(OpenSslContextOption.GROUPS, groups);
                }
                return b.build();
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
                SslContextBuilder b = SslContextBuilder.forServer(crt, key)
                        .sslProvider(sslProvider());
                String[] groups = configuredGroups();
                if (groups != null && sslProvider() != SslProvider.JDK) {
                    b.option(OpenSslContextOption.GROUPS, groups);
                }
                return b.build();
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }

        SSLEngine newClientEngine(ByteBufAllocator allocator, String cipher) {
            return configureEngine(clientContext().newHandler(allocator).engine(), cipher);
        }

        SSLEngine newServerEngine(ByteBufAllocator allocator, String cipher) {
            return configureEngine(serverContext().newHandler(allocator).engine(), cipher);
        }

        abstract SslProvider sslProvider();

        static SSLEngine configureEngine(SSLEngine engine, String cipher) {
            engine.setEnabledProtocols(new String[]{ protocolOf(cipher) });
            engine.setEnabledCipherSuites(new String[]{ cipher });
            return engine;
        }
    }

    public enum BufferType {
        HEAP {
            @Override
            CleanableDirectBuffer newBuffer(int size) {
                ByteBuffer byteBuffer = ByteBuffer.allocate(size);
                return new CleanableDirectBuffer() {
                    @Override
                    public ByteBuffer buffer() {
                        return byteBuffer;
                    }

                    @Override
                    public void clean() {
                        // NOOP
                    }
                };
            }
        },
        DIRECT {
            @Override
            CleanableDirectBuffer newBuffer(int size) {
                return PlatformDependent.allocateDirect(size);
            }
        };

        abstract CleanableDirectBuffer newBuffer(int size);
    }

    @Param
    public SslEngineProvider sslProvider;

    @Param
    public BufferType bufferType;

    // Includes cipher required by HTTP/2
    @Param({ "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
             "TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384" })
    public String cipher;

    protected SSLEngine clientEngine;
    protected SSLEngine serverEngine;

    private CleanableDirectBuffer cleanableCTOs;
    private CleanableDirectBuffer cleanableSTOc;
    private CleanableDirectBuffer cleanableServerAppReadBuffer;
    private CleanableDirectBuffer cleanableClientAppReadBuffer;
    private CleanableDirectBuffer cleanableEmpty;

    private ByteBuffer cTOs;
    private ByteBuffer sTOc;
    private ByteBuffer serverAppReadBuffer;
    private ByteBuffer clientAppReadBuffer;
    private ByteBuffer empty;

    protected final void initEngines(ByteBufAllocator allocator) {
        clientEngine = newClientEngine(allocator);
        serverEngine = newServerEngine(allocator);
    }

    protected final void destroyEngines() {
        ReferenceCountUtil.release(clientEngine);
        ReferenceCountUtil.release(serverEngine);
    }

    protected final void initHandshakeBuffers() {
        cleanableCTOs = allocateBuffer(clientEngine.getSession().getPacketBufferSize());
        cleanableSTOc = allocateBuffer(serverEngine.getSession().getPacketBufferSize());
        cleanableServerAppReadBuffer = allocateBuffer(
                serverEngine.getSession().getApplicationBufferSize());
        cleanableClientAppReadBuffer = allocateBuffer(
                clientEngine.getSession().getApplicationBufferSize());
        cleanableEmpty = allocateBuffer(0);

        cTOs = cleanableCTOs.buffer();
        sTOc = cleanableSTOc.buffer();
        serverAppReadBuffer = cleanableServerAppReadBuffer.buffer();
        clientAppReadBuffer = cleanableClientAppReadBuffer.buffer();
        empty = cleanableEmpty.buffer();
    }

    protected final void destroyHandshakeBuffers() {
        cleanableCTOs.clean();
        cleanableSTOc.clean();
        cleanableServerAppReadBuffer.clean();
        cleanableClientAppReadBuffer.clean();
        cleanableEmpty.clean();
    }

    /**
     * Drives both engines to a completed handshake, each according to its own
     * {@link SSLEngineResult.HandshakeStatus}.
     *
     * <p>The previous version ran the two engines in lock step -- both wrap, both unwrap, stop when
     * both had reported {@code FINISHED} -- which is shaped around the TLS 1.2 message flow and
     * cannot complete a TLS 1.3 one. In TLS 1.3 the client reports {@code FINISHED} as soon as it
     * has unwrapped the server's Finished, while it still has its own Finished to send; a
     * finished-flag loop skips that wrap, the server never completes, and the buffers desynchronise
     * into {@code SSLException: Unrecognized SSL message, plaintext connection?}. TLS 1.3 also
     * sends NewSessionTicket after the handshake proper, which the same loop had no way to drain.
     *
     * <p>Asking each engine what it wants next handles both protocol versions without special
     * cases. {@code idle} is the termination guard: an engine that is neither wrapping nor
     * unwrapping and has no buffered input has nothing left to contribute.
     */
    protected final boolean doHandshake() throws SSLException {
        // The engines are recreated per invocation but the buffers are allocated once per iteration
        // and reused, so a handshake has to start from empty ones. TLS 1.2 happened to drain them;
        // TLS 1.3 sends NewSessionTicket after the handshake proper, and those bytes left in sTOc
        // are read by the next invocation's fresh client engine as the start of a new stream --
        // "Unrecognized SSL message, plaintext connection?".
        cTOs.clear();
        sTOc.clear();
        clientAppReadBuffer.clear();
        serverAppReadBuffer.clear();

        clientEngine.beginHandshake();
        serverEngine.beginHandshake();

        SSLEngineResult clientResult = null;
        SSLEngineResult serverResult = null;
        int idle = 0;

        while (isHandshaking(clientEngine) || isHandshaking(serverEngine)) {
            boolean progress = false;

            if (wants(clientEngine, SSLEngineResult.HandshakeStatus.NEED_WRAP)) {
                clientResult = clientEngine.wrap(empty, cTOs);
                runDelegatedTasks(clientResult, clientEngine);
                progress |= clientResult.bytesProduced() > 0;
            }
            if (wants(serverEngine, SSLEngineResult.HandshakeStatus.NEED_WRAP)) {
                serverResult = serverEngine.wrap(empty, sTOc);
                runDelegatedTasks(serverResult, serverEngine);
                progress |= serverResult.bytesProduced() > 0;
            }

            cTOs.flip();
            sTOc.flip();

            if (sTOc.hasRemaining() && wants(clientEngine, SSLEngineResult.HandshakeStatus.NEED_UNWRAP)) {
                clientResult = clientEngine.unwrap(sTOc, clientAppReadBuffer);
                runDelegatedTasks(clientResult, clientEngine);
                progress |= clientResult.bytesConsumed() > 0;
            }
            if (cTOs.hasRemaining() && wants(serverEngine, SSLEngineResult.HandshakeStatus.NEED_UNWRAP)) {
                serverResult = serverEngine.unwrap(cTOs, serverAppReadBuffer);
                runDelegatedTasks(serverResult, serverEngine);
                progress |= serverResult.bytesConsumed() > 0;
            }

            sTOc.compact();
            cTOs.compact();

            if (progress) {
                idle = 0;
            } else if (++idle > 8) {
                break;
            }
        }

        return clientResult != null && serverResult != null &&
                clientResult.getStatus() == SSLEngineResult.Status.OK &&
                serverResult.getStatus() == SSLEngineResult.Status.OK;
    }

    /**
     * True while the engine still has handshake work of its own. NOT_HANDSHAKING and FINISHED both
     * mean "nothing more from this side"; FINISHED is only ever reported once, on the result that
     * completes it.
     */
    private static boolean isHandshaking(SSLEngine engine) {
        SSLEngineResult.HandshakeStatus status = engine.getHandshakeStatus();
        return status != SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING &&
               status != SSLEngineResult.HandshakeStatus.FINISHED;
    }

    private static boolean wants(SSLEngine engine, SSLEngineResult.HandshakeStatus status) {
        SSLEngineResult.HandshakeStatus current = engine.getHandshakeStatus();
        // NEED_TASK is resolved by runDelegatedTasks after the call, so an engine sitting on it
        // still needs to be driven; treat it as willing to do either.
        return current == status || current == SSLEngineResult.HandshakeStatus.NEED_TASK;
    }

    protected final SSLEngine newClientEngine(ByteBufAllocator allocator) {
        return sslProvider.newClientEngine(allocator, cipher);
    }

    protected final SSLEngine newServerEngine(ByteBufAllocator allocator) {
        return sslProvider.newServerEngine(allocator, cipher);
    }

    static boolean checkSslEngineResult(SSLEngineResult result, ByteBuffer src, ByteBuffer dst) {
        return result.getStatus() == SSLEngineResult.Status.OK && !src.hasRemaining() && dst.hasRemaining();
    }

    protected final CleanableDirectBuffer allocateBuffer(int size) {
        return bufferType.newBuffer(size);
    }

    private static void runDelegatedTasks(SSLEngineResult result, SSLEngine engine) {
        if (result.getHandshakeStatus() == SSLEngineResult.HandshakeStatus.NEED_TASK) {
            for (;;) {
                Runnable task = engine.getDelegatedTask();
                if (task == null) {
                    break;
                }
                task.run();
            }
        }
    }
}
