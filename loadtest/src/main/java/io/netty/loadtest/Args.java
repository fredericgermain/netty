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

import java.util.HashMap;
import java.util.Map;

/** {@code --key=value} arguments, with the defaults kept at the call sites. */
final class Args {

    private final Map<String, String> values = new HashMap<>();

    static Args parse(String[] argv) {
        Args a = new Args();
        for (String s : argv) {
            if (s.startsWith("--")) {
                int eq = s.indexOf('=');
                if (eq < 0) {
                    a.values.put(s.substring(2), "true");
                } else {
                    a.values.put(s.substring(2, eq), s.substring(eq + 1));
                }
            }
        }
        return a;
    }

    String get(String key, String dflt) {
        return values.getOrDefault(key, dflt);
    }

    int getInt(String key, int dflt) {
        String v = values.get(key);
        return v == null ? dflt : Integer.parseInt(v);
    }

    long getLong(String key, long dflt) {
        String v = values.get(key);
        return v == null ? dflt : Long.parseLong(v);
    }

    boolean has(String key) {
        return values.containsKey(key);
    }

    /** {@code --flag} or {@code --flag=true}. An explicit {@code --flag=false} switches it off. */
    boolean flag(String key) {
        String v = values.get(key);
        return v != null && !"false".equalsIgnoreCase(v);
    }

    Transports transport() {
        return Transports.parse(get("transport", "nio"));
    }

    /**
     * Event loop threads. Left explicit rather than defaulted to core count, because the client and
     * server are pinned to disjoint cores and each should size to its own share, not to the whole
     * machine.
     */
    int threads() {
        return getInt("threads", Runtime.getRuntime().availableProcessors());
    }
}
