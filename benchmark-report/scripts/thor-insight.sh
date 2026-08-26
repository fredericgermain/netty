#!/bin/bash
# Insight-mode run on an idle machine, to decide whether the musl-vs-glibc gap seen in gate mode
# is real. Gate mode is -f 1 -wi 1 -i 2 and is only good for pass/fail; this is -f 3 -wi 5 -i 10.
#
# Two provider families, each across glibc and both musl images:
#   openssl-dynamic 2.0.81  (released; the only flavour whose cells pass on released tcnative)
#   boringssl-static 2.0.82 (patched; the flavour that will ship)
set -u
cd /home/fred/tls-matrix/netty || exit 2
OUT=/home/fred/tls-matrix
IMAGES="eclipse-temurin:21-jdk eclipse-temurin:21-jdk-alpine amazoncorretto:21-alpine"

rm -rf "$OUT/insight"
for img in $IMAGES; do
  echo "############ insight openssl-dynamic on $img"
  .github/scripts/tls-matrix/run.sh --jar "$OUT/mb-openssl.jar" --image "$img" \
    --tcnative openssl --mode insight --out "$OUT/insight" --expect 4 \
    -p sslProvider=JDK,OPENSSL -p bufferType=DIRECT \
    -p cipher=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_AES_128_GCM_SHA256 2>&1 | tail -8
done

for img in $IMAGES; do
  echo "############ insight boringssl-static patched on $img"
  .github/scripts/tls-matrix/run.sh --jar "$OUT/mb-patched.jar" --image "$img" \
    --tcnative boringssl --mode insight --out "$OUT/insight-bssl" --expect 4 \
    -p sslProvider=JDK,OPENSSL -p bufferType=DIRECT \
    -p cipher=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_AES_128_GCM_SHA256 2>&1 | tail -8
done
echo INSIGHT_DONE
