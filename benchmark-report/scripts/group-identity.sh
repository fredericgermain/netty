#!/bin/bash
# Which key exchange group does BoringSSL pick when nothing tells it to?
#
# Usage: group-identity.sh [jar]      (default: loadtest/target/loadtest.jar)
#
# A5 established that BoringSSL's TLS 1.3 default *costs what X25519MLKEM768 costs*, and said so:
# "Does not establish that the default is X25519MLKEM768 by identity. A packet capture or an
# SSL_get_negotiated_group() call would settle it directly and neither was done." This is that call.
# openssl s_client -brief reports SSL_get_negotiated_group's answer, so pointing it at a netty server
# running tcnative/BoringSSL reads the selection off the wire instead of inferring it from a score.
#
# Two parts. The probe: four client offers against a server with no group configured, so the server's
# own preference decides. The control: the same client offer against a server pinned to X25519, which
# must come back X25519 -- otherwise the probe is reading something other than the server's choice.
#
# Not a timed benchmark. Needs docker and a glibc image (released boringssl-static does not load on
# musl -- that is A2).
set -u

JAR=${1:-$PWD/loadtest/target/loadtest.jar}
IMG=${IMG:-eclipse-temurin:21-jdk}
PORT=${PORT:-19997}
PORT2=$((PORT - 1))

[ -f "$JAR" ] || { echo "no jar at $JAR -- build it per loadtest/README.md" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

cleanup() { docker rm -f gi-srv gi-srv-pinned >/dev/null 2>&1; }
trap cleanup EXIT

start() {  # start <name> <port> <groups>
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --rm --name "$1" --network=host --security-opt seccomp=unconfined \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -Dnetty.loadtest.tls.groups="$3" -jar /app/lt.jar server \
      --transport=epoll --tls=openssl --port="$2" --threads=2 --backlog=128 >/dev/null
  for _ in $(seq 1 40); do
    docker logs "$1" 2>&1 | grep -q '^READY' && return 0
    sleep 0.5
  done
  echo "$1 never reported READY: $(docker logs "$1" 2>&1 | tail -2 | tr '\n' ' ')" >&2
  return 1
}

group() {  # group <port> [offer]
  local args=(-connect "127.0.0.1:$1" -brief)
  [ -n "${2:-}" ] && args+=(-groups "$2")
  printf '' | timeout 15 openssl s_client "${args[@]}" 2>&1 | awk '
    /^Protocol version:/        { p=$3 }
    /^Ciphersuite:/             { c=$2 }
    /^Negotiated TLS1.3 group:/ { g=$4 }
    /^Peer Temp Key:/           { t=$4; if (t == "ECDH,") t=$5; sub(/,$/, "", t) }
    END { printf "%-8s %-28s %s\n", (p == "" ? "FAILED" : p), c, (g != "" ? g : (t != "" ? t : "-")) }'
}

echo "date       $(date -Is)"
echo "client     $(openssl version)"
echo "image      $IMG"
echo "jar        $JAR"
# The jar carries no Implementation-Version -- the shade plugin writes none -- so read the netty
# version the way scripts/calibrate.sh does, from the transport module's pom.properties.
if command -v unzip >/dev/null; then
  unzip -p "$JAR" META-INF/maven/io.netty/netty-transport/pom.properties 2>/dev/null \
    | sed -n 's/^version=/netty      /p'
fi
echo

start gi-srv "$PORT" "" || exit 1
echo "=== server built with no group option: BoringSSL's own preference decides"
printf '%-30s %s\n' offer "version  ciphersuite                  group"
for g in "" "X25519MLKEM768:X25519:P-256" "X25519:P-256" "P-256"; do
  printf '%-30s ' "${g:-<client default>}"
  group "$PORT" "$g"
done

start gi-srv-pinned "$PORT2" X25519 || exit 1
echo
echo "=== control: server pinned to X25519, client still offers the hybrid first"
printf '%-30s ' "X25519MLKEM768:X25519:P-256"
group "$PORT2" "X25519MLKEM768:X25519:P-256"

echo
echo IDENTITY_DONE
