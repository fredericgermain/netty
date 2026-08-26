#!/bin/bash
# Build the three benchmark jar flavours for linux-x86_64 on thor, then run the matrix twice:
# once against released tcnative and once against the patched snapshot.
set -u
cd /home/fred/tls-matrix/netty || exit 2
OUT=/home/fred/tls-matrix
MVN="./mvnw -B -ntp -pl microbench -Pbenchmark-jar package -DskipTests=true -Drevapi.skip=true -Dcheckstyle.skip=true -Dforbiddenapis.skip=true -Dxml.skip=true -Dtcnative.classifier=linux-x86_64"
DC() { docker compose -f docker/docker-compose.yaml -f docker/docker-compose.centos-7.111.yaml \
         run --rm --entrypoint /bin/bash shell -lc "cd /code && $1"; }

echo "=== 1/3 boringssl-static, released 2.0.81"
DC "$MVN -Dtcnative.artifactId=netty-tcnative-boringssl-static" > "$OUT/jar-released.log" 2>&1 \
  && cp microbench/target/microbenchmarks.jar "$OUT/mb-released.jar" && echo "  ok" || echo "  FAILED"

echo "=== 2/3 boringssl-static, patched 2.0.82-SNAPSHOT (netty's boringssl-snapshot profile)"
DC "./mvnw -B -ntp -pl microbench -Pbenchmark-jar,boringssl-snapshot package -DskipTests=true -Drevapi.skip=true -Dcheckstyle.skip=true -Dforbiddenapis.skip=true -Dxml.skip=true -Dtcnative.classifier=linux-x86_64" > "$OUT/jar-patched.log" 2>&1 \
  && cp microbench/target/microbenchmarks.jar "$OUT/mb-patched.jar" && echo "  ok" || echo "  FAILED"

echo "=== 3/3 openssl-dynamic, released 2.0.81 (x86_64 only -- no linux-aarch_64 classifier exists)"
DC "$MVN -Dtcnative.artifactId=netty-tcnative" > "$OUT/jar-openssl.log" 2>&1 \
  && cp microbench/target/microbenchmarks.jar "$OUT/mb-openssl.jar" && echo "  ok" || echo "  FAILED"

ls -l "$OUT"/mb-*.jar 2>/dev/null

echo
echo "############ matrix: RELEASED tcnative, all three images"
rm -rf "$OUT/res-released"
.github/scripts/tls-matrix/matrix.sh \
  --jar-boringssl "$OUT/mb-released.jar" --jar-openssl "$OUT/mb-openssl.jar" \
  --out "$OUT/res-released"
echo "RELEASED_EXIT=$?"

echo
echo "############ matrix: PATCHED tcnative, all three images"
rm -rf "$OUT/res-patched"
.github/scripts/tls-matrix/matrix.sh \
  --jar-boringssl "$OUT/mb-patched.jar" \
  --out "$OUT/res-patched"
echo "PATCHED_EXIT=$?"
echo "ALL_DONE"
