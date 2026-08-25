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

import io.netty.handler.ssl.OpenSsl;
import io.netty.handler.ssl.OpenSslContextOption;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.SslProvider;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.pkitesting.CertificateBuilder;
import io.netty.pkitesting.X509Bundle;

/**
 * TLS contexts for the load test, and the assertions that keep a run honest.
 *
 * <p>Two things are deliberately fatal rather than silent. A requested provider that is not
 * actually loaded aborts, because netty resolves {@link SslProvider#OPENSSL} to whichever native
 * library is on the classpath and would otherwise publish one provider's number under another's
 * name. And the key exchange group is pinned when asked, because a TLS 1.3 cipher suite does not
 * name its key exchange: leave it unpinned and BoringSSL will negotiate a post-quantum hybrid
 * while a TLS 1.2 run does classical ECDHE, which is a ~33% difference attributed to the wrong
 * thing.
 */
final class Tls {

    /** Self-signed, generated in process. No keytool step, works in any image. */
    private static final X509Bundle CERT;
    static {
        try {
            CERT = new CertificateBuilder().subject("CN=loadtest").setIsCertificateAuthority(true)
                    .buildSelfSigned();
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private Tls() { }

    static SslContext serverContext(String mode) throws Exception {
        if ("none".equals(mode)) {
            return null;
        }
        SslContextBuilder b = SslContextBuilder
                .forServer(CERT.getKeyPair().getPrivate(), CERT.getCertificatePath())
                .sslProvider(provider(mode));
        return build(b, mode);
    }

    static SslContext clientContext(String mode) throws Exception {
        if ("none".equals(mode)) {
            return null;
        }
        SslContextBuilder b = SslContextBuilder.forClient()
                .trustManager(InsecureTrustManagerFactory.INSTANCE)
                .sslProvider(provider(mode));
        return build(b, mode);
    }

    private static SslContext build(SslContextBuilder b, String mode) throws Exception {
        String groups = System.getProperty("netty.loadtest.tls.groups", "");
        if (!groups.isEmpty() && !"jdk".equals(mode)) {
            b.option(OpenSslContextOption.GROUPS, groups.split(","));
        }
        String protocols = System.getProperty("netty.loadtest.tls.protocols", "");
        if (!protocols.isEmpty()) {
            b.protocols(protocols.split(","));
        }
        return b.build();
    }

    private static SslProvider provider(String mode) {
        switch (mode) {
            case "jdk":
                return SslProvider.JDK;
            case "openssl":
                if (!OpenSsl.isAvailable()) {
                    throw new IllegalStateException("tls=openssl requested but tcnative is unavailable",
                            OpenSsl.unavailabilityCause());
                }
                return SslProvider.OPENSSL;
            default:
                throw new IllegalArgumentException("--tls must be none, jdk or openssl, got: " + mode);
        }
    }

    /** For the run header, so results record what was actually loaded rather than what was asked for. */
    static String describe(String mode) {
        if ("openssl".equals(mode)) {
            return OpenSsl.isAvailable() ? OpenSsl.versionString() : "UNAVAILABLE";
        }
        return mode;
    }
}
