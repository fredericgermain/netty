#!/bin/bash
# 10k concurrent TLS connections, on thor, client and server in separate containers pinned to
# disjoint cores so the load generator does not compete with the thing being measured.
set -u
JAR=/home/fred/tls-matrix/netty/loadtest/target/loadtest.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=${CONNS:-10000}
DUR=${DUR:-15}

# 10k connections is ~20k descriptors on each side. somaxconn has to match SO_BACKLOG or the
# kernel silently truncates the accept queue and the ramp stalls rather than failing.
echo "host somaxconn=$(cat /proc/sys/net/core/somaxconn) ephemeral=$(cat /proc/sys/net/ipv4/ip_local_port_range)"

cell() {  # cell <transport> <tls> <groups>
  local t=$1 tls=$2 groups=${3:-}
  local name="load-$t-$tls"
  docker rm -f "$name-srv" >/dev/null 2>&1
  docker run -d --rm --name "$name-srv" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -Dnetty.loadtest.tls.groups="$groups" -jar /app/lt.jar server \
      --transport="$t" --tls="$tls" --port=19999 --threads=4 --backlog=8192 >/dev/null
  # Wait for READY rather than sleeping a guess.
  for i in $(seq 1 40); do
    docker logs "$name-srv" 2>&1 | grep -q '^READY' && break
    sleep 0.5
  done
  if ! docker logs "$name-srv" 2>&1 | grep -q '^READY'; then
    printf '%-26s SERVER FAILED: %s\n' "$t/$tls" "$(docker logs "$name-srv" 2>&1 | tail -2 | tr '\n' ' ')"
    docker rm -f "$name-srv" >/dev/null 2>&1
    return
  fi

  printf '%-26s ' "$t/$tls${groups:+/$groups}"
  docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -Dnetty.loadtest.tls.groups="$groups" -jar /app/lt.jar client \
      --transport="$t" --tls="$tls" --host=127.0.0.1 --port=19999 \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 2>&1 \
    > /tmp/client.out 2>&1
  grep -E '^RAMP|^STEADY' /tmp/client.out | tr '\n' ' '
  echo
  if ! grep -q '^STEADY' /tmp/client.out; then
    echo "    NO STEADY LINE -- client tail:"
    tail -6 /tmp/client.out | sed 's/^/      /'
  fi
  docker rm -f "$name-srv" >/dev/null 2>&1
}

echo
echo "=== $CONNS connections, ${DUR}s steady state, 1KB payload"
echo "--- plaintext: the transport ceiling, no crypto in the way"
cell nio     none
cell epoll   none
cell io_uring none

echo
echo "--- TLS via tcnative/BoringSSL"
cell nio     openssl
cell epoll   openssl
cell io_uring openssl

echo
echo "--- TLS via the JDK provider, same transports"
cell epoll   jdk

echo LOAD_DONE
