#!/bin/bash
# The io_uring TLS cells trended upward across FRESH JVMs (70442, 82764, 111042, 115721, 115189)
# while epoll's TLS cells showed no trend. Each round was a new process, so it is not JIT. Two
# families of explanation are left: machine state that develops across the hour (cpufreq governor
# is "powersave", so sustained load raises the running frequency; thermal and cache state too), or
# something about the alternation with the other cells in the q3 interleave.
#
# Discriminator: run the SAME cell ten times consecutively, nothing else in between. Machine state
# predicts the early rounds low and a plateau within a few rounds, reproducing the original shape
# without any alternation. Per-round frequency and temperature are logged so the machine-state
# story can be checked directly instead of inferred.
#
# Old pinning (server 0-3, client 4-7) is kept deliberately: the trend under investigation was
# measured under it, and reproducing an anomaly means reproducing its conditions.
set -u
JAR=/home/fred/tls-matrix/loadtest-pin.jar
IMG=eclipse-temurin:21-jdk-alpine
CONNS=10000
DUR=10
PAY=1024
TAG=tlswarm

PORT=0
for p in $(seq 19990 20050); do
  if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }
echo "port=$PORT conns=$CONNS payload=$PAY dur=$DUR"

machine() {
  local f t
  f=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo -)
  t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1 || echo -)
  echo "freqKHz=$f tempMilliC=$t load1m=$(cut -d" " -f1 /proc/loadavg)"
}

one() {  # one <transport>
  local t=$1
  local name="$TAG-srv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" --network=host --cpuset-cpus=0-3 \
    --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
    -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar server --transport="$t" --tls=openssl --port=$PORT \
         --threads=4 --backlog=8192 >/dev/null
  local ok=0
  for i in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q '^READY' && { ok=1; break; }; sleep 0.5; done
  [ "$ok" = 0 ] && { echo "SRVFAIL"; docker logs "$name" 2>&1 | tail -3; docker rm -f "$name" >/dev/null 2>&1; return; }

  timeout 150 docker run --rm --network=host --cpuset-cpus=4-7 --security-opt seccomp=unconfined \
    --ulimit nofile=65536:65536 -v "$JAR:/app/lt.jar:ro" "$IMG" \
    java -jar /app/lt.jar client --transport="$t" --tls=openssl --host=127.0.0.1 --port=$PORT \
      --connections=$CONNS --duration=$DUR --payload=$PAY --threads=4 > /tmp/$TAG.out 2>&1

  local rps ramp
  rps=$(grep '^STEADY' /tmp/$TAG.out | sed -E 's/.*reqPerSec=([0-9]+).*/\1/')
  ramp=$(grep '^RAMP' /tmp/$TAG.out | sed -E 's/.*connPerSec=([0-9]+).*/\1/')
  echo "rps=${rps:-FAIL} rampConnPerSec=${ramp:--} $(machine)"
  docker rm -f "$name" >/dev/null 2>&1
}

echo "=== ten consecutive io_uring TLS rounds, fresh JVMs"
for r in $(seq 1 10); do
  printf 'ur-%02d  ' "$r"
  one io_uring
done

echo "=== ten consecutive epoll TLS rounds, fresh JVMs"
for r in $(seq 1 10); do
  printf 'ep-%02d  ' "$r"
  one epoll
done
echo TLSWARM_DONE
