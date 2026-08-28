#!/bin/bash
# Build codec-native-quic from quic-musl-compat, so QUIC can be measured on Alpine.
#
# QUIC is the only sweep in this branch running on glibc; every Part D number is musl. The reason is
# that the released native artifact carries ld-linux-x86-64.so.2 in DT_NEEDED, which musl never
# resolves, so it cannot load at all on Alpine. The quic-musl-compat branch fixes that the same way
# tcnative #997 did, and this build is also the first time that fix will carry real traffic: it has
# only ever been exercised by QuicMuslCheck.java at load/init/handshake, meaning one handshake.
#
# Built inside netty:centos-7-1.11 because the pom clones and compiles BoringSSL and quiche from
# source, and quiche is Rust. That image already carries Go and Rust and is already on this host.
set -euo pipefail

SRC=/home/fred/netty-quic
IMG=netty:centos-7-1.11
OUT=/home/fred/quic-musl-build.log

cd "$SRC"

# -o would be wrong here: the build has to reach googlesource.com and github.com for the two pinned
# source trees. Only the netty artifacts come from the local repository.
#
# Skipping tests and javadoc deliberately. The question this build answers is whether the .so loads
# on musl, and that is checked afterwards by loading it, not by anything the build itself reports.
docker run --rm \
  -v "$SRC:/code" -w /code \
  -v /home/fred/.m2:/root/.m2 \
  --network=host \
  "$IMG" \
  bash -lc '
    source ~/.bashrc 2>/dev/null || true
    export PATH=/opt/go/bin:$HOME/.cargo/bin:$PATH
    echo "== toolchain"
    go version || echo "NO GO"
    cargo --version || echo "NO CARGO"
    cmake --version | head -1 || echo "NO CMAKE"
    echo "== building codec-native-quic"
    ./mvnw -q -pl codec-native-quic -am \
      -DskipTests -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true \
      -Dxml.skip=true -Drevapi.skip=true -Danimal.sniffer.skip=true \
      install
  ' 2>&1 | tee "$OUT" | tail -40

echo "== BUILD_EXIT=${PIPESTATUS[0]}"
echo "== produced jars:"
ls -la "$SRC"/codec-native-quic/target/*.jar 2>/dev/null | awk '{print $5, $9}'
echo BUILD_DONE
