#!/bin/bash
# Does arming multishot recv close io_uring's plaintext deficit?
#
# Netty only sets IORING_RECV_MULTISHOT inside scheduleReadProviderBuffer(), which is reached only
# when a provided buffer ring is configured, and IoUringIoHandlerConfig configures none by default.
# So every measurement in this branch so far ran io_uring in one-shot recv: an SQE prepared,
# submitted, reaped and re-armed for every single read. The ctimer profile matched that exactly --
# no dominant frame, just a long tail of handleFastPath, jctools accessors and writeComplete0.
#
# Four cells, interleaved. epoll is the control and should not move; if it does, the machine is
# drifting and the io_uring numbers cannot be read either.
set -u
JAR=/home/fred/tls-matrix/loadtest-br.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=10
ROUNDS=5

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

one() {
  local t=$1
  local br=$2
  local name="br-$t-$br"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=none --port=$PORT \
         --threads=4 --backlog=8192 --buffer-ring="$br" >/dev/null
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && break; sleep 0.5; done
  docker logs "$name" 2>&1 | grep -q '^READY' || { echo "SERVERFAIL"; docker rm -f "$name" >/dev/null 2>&1; return; }

  timeout 120 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=none --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=1024 --threads=4 --buffer-ring="$br" \
    > /tmp/br.out 2>&1

  local rps u s
  rps=$(grep '^STEADY' /tmp/br.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  u=$(grep '^CLIENTCPU' /tmp/br.out | sed -E 's/.*utimeUsPerReq=([0-9.]+).*/\1/')
  s=$(grep '^CLIENTCPU' /tmp/br.out | sed -E 's/.*stimeUsPerReq=([0-9.]+).*/\1/')
  printf '%-10s' "${rps:--}"
  echo "$t br=$br rps=${rps:--} cliU=${u:--} cliS=${s:--}" >> /tmp/br-detail.log
  docker rm -f "$name" >/dev/null 2>&1
}

: > /tmp/br-detail.log
echo "round  epoll      iouring    iouring+br iouring+br"
echo "                  (br=0)     (1024)     (4096)"
for r in $(seq 1 $ROUNDS); do
  printf '%-6s ' "$r"
  one epoll    0
  one io_uring 0
  one io_uring 1024
  one io_uring 4096
  echo
done
echo "--- per-cell CPU detail:"
cat /tmp/br-detail.log
echo BUFRING_DONE
