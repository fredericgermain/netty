#!/bin/bash
# Is the "TLS 1.3 is slower than TLS 1.2" observation a protocol effect or a key-exchange-group
# artefact? Vary the group with everything else held fixed, on an idle host, insight settings.
set -u
cd /home/fred/tls-matrix/netty || exit 2
OUT=/home/fred/tls-matrix
IMG=eclipse-temurin:21-jdk-alpine

echo "=== rebuilding the patched jar with the groups option"
docker compose -f docker/docker-compose.yaml -f docker/docker-compose.centos-7.111.yaml \
  run --rm --entrypoint /bin/bash shell -lc \
  "cd /code && ./mvnw -B -ntp -pl microbench -Pbenchmark-jar,boringssl-snapshot package -DskipTests=true -Drevapi.skip=true -Dcheckstyle.skip=true -Dforbiddenapis.skip=true -Dxml.skip=true -Dtcnative.classifier=linux-x86_64" \
  > "$OUT/jar-groups.log" 2>&1 && cp microbench/target/microbenchmarks.jar "$OUT/mb-groups.jar" \
  && echo "  ok" || { echo "  FAILED"; exit 1; }

run() {  # run <label> <cipher> <groups>
  printf '%-46s ' "$1"
  docker run --rm -v "$OUT/mb-groups.jar:/app/mb.jar:ro" "$IMG" \
    java -jar /app/mb.jar SslEngineHandshakeBenchmark \
      -f 3 -wi 5 -i 10 -r 2s -w 2s \
      -p sslProvider=OPENSSL -p bufferType=DIRECT -p cipher="$2" \
      -jvmArgsAppend "-Dnetty.bench.tls.groups=$3" 2>&1 \
    | grep -E '^SslEngineHandshake' | awk '{print $(NF-3), $(NF-2), $(NF-1), $NF}'
}

echo
echo "=== BoringSSL, TLS 1.3, group varied (everything else fixed)"
run "TLS1.3  group=<provider default>" TLS_AES_128_GCM_SHA256 ""
run "TLS1.3  group=X25519 (classical)" TLS_AES_128_GCM_SHA256 "X25519"
run "TLS1.3  group=X25519MLKEM768 (what S3 uses)" TLS_AES_128_GCM_SHA256 "X25519MLKEM768"
run "TLS1.3  group=P-256" TLS_AES_128_GCM_SHA256 "P-256"

echo
echo "=== same group on both protocol versions -- the apples-to-apples comparison"
run "TLS1.2  group=X25519" TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 "X25519"
run "TLS1.3  group=X25519" TLS_AES_128_GCM_SHA256 "X25519"
run "TLS1.2  group=P-256" TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 "P-256"
run "TLS1.3  group=P-256" TLS_AES_128_GCM_SHA256 "P-256"
echo GROUPS_DONE
