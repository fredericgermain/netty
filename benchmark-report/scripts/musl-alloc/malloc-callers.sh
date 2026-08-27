#!/bin/bash
# Which call sites allocate, during a QUIC load on musl?
#
# Pivot from __lock to malloc, for two reasons. bpftrace cannot resolve __lock (a local symbol, and
# its address form errors with "Could not resolve address"), while malloc is a proper dynamic
# symbol. And it loses nothing: every malloc takes the mallocng lock, so malloc's callers ARE the
# lock's callers, one level up and easier to attribute.
#
# The sanity probe already showed the scale: 1,737,381 mallocs in 2 s on the server, roughly 870k/s
# and about 16 per request. That rate is the reason the lock matters at all.
#
# Return address from [rsp] at entry rather than ustack(), since neither musl nor quiche is built
# with frame pointers. One frame is enough: it says which library, and with the debug symbols, which
# function.
set -u
JAR=/tmp/loadtest-published.jar
IMG=alpine-jdk-musl-alloc
OUT=/tmp/malloccallers
CONNS=500
TRACE_SECS=${TRACE_SECS:-3}

rm -rf "$OUT"; mkdir -p "$OUT"

PORT=0
for p in $(seq 20290 20340); do
  if ! ss -tln 2>/dev/null | grep -q ":$p " && ! ss -uln 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port" >&2; exit 2; }

docker rm -f m-srv m-cli >/dev/null 2>&1
docker run -d --rm --name m-srv --network=host --cpuset-cpus=0,1,4,5 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar server --protocol=quic --transport=epoll --port=$PORT \
    --payload=1024 --threads=4 >/dev/null 2>&1
for i in $(seq 1 60); do docker logs m-srv 2>&1 | grep -q '^READY' && break; sleep 0.5; done
docker logs m-srv 2>&1 | grep -q '^READY' || { echo SERVER_FAILED; docker rm -f m-srv >/dev/null 2>&1; exit 1; }
PID=$(docker inspect -f '{{.State.Pid}}' m-srv)
MUSL="/proc/$PID/root/lib/ld-musl-x86_64.so.1"

docker run -d --rm --name m-cli --network=host --cpuset-cpus=2,3,6,7 \
  --security-opt seccomp=unconfined --ulimit nofile=65536:65536 \
  -v "$JAR:/app/lt.jar:ro" "$IMG" \
  java -jar /app/lt.jar client --protocol=quic --transport=epoll --host=127.0.0.1 --port=$PORT \
    --connections=$CONNS --duration=90 --payload=1024 --threads=4 >/dev/null 2>&1
sleep 8

sudo -n cat "/proc/$PID/maps" > "$OUT/maps.txt"
echo "pid=$PID  tracing malloc callers for ${TRACE_SECS}s"

sudo -n timeout $((TRACE_SECS + 10)) bpftrace -e "
uprobe:$MUSL:malloc /pid == $PID/ {
    @caller[*(uint64*)reg(\"sp\")] = count();
}
interval:s:$TRACE_SECS { exit(); }
" > "$OUT/raw.txt" 2>"$OUT/err.txt"

docker rm -f m-srv m-cli >/dev/null 2>&1

# Resolve each address against the mappings captured above: find the region containing it, subtract
# the region base, add the file offset, then look the result up in that file's symbols.
python3 - "$OUT" <<'PY'
import re, subprocess, sys, os
out = sys.argv[1]
regions = []
for line in open(os.path.join(out, "maps.txt")):
    m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+) ([0-9a-f]+) \S+ \S+\s+(.*)", line)
    if not m: continue
    lo, hi, perms, off, path = m.groups()
    if "x" not in perms or not path.strip(): continue
    regions.append((int(lo,16), int(hi,16), int(off,16), path.strip()))

counts = {}
for line in open(os.path.join(out, "raw.txt")):
    m = re.match(r"@caller\[(\d+)\]: (\d+)", line.strip())
    if m: counts[int(m.group(1))] = int(m.group(2))
if not counts:
    print("  (no samples)"); sys.exit()

total = sum(counts.values())
by_lib = {}
rows = []
for addr, n in sorted(counts.items(), key=lambda kv: -kv[1])[:400]:
    lib, fileoff = "?", 0
    for lo, hi, off, path in regions:
        if lo <= addr < hi:
            lib, fileoff = path, addr - lo + off
            break
    by_lib[lib] = by_lib.get(lib, 0) + n
    rows.append((n, lib, fileoff))

print("=== malloc callers by library (%d sampled calls)" % total)
for lib, n in sorted(by_lib.items(), key=lambda kv: -kv[1])[:8]:
    print("  %6.2f%%  %-9d %s" % (100.0*n/total, n, lib))

print("\n=== top individual call sites")
cache = {}
for n, lib, fileoff in rows[:12]:
    key = (lib, fileoff)
    if key not in cache:
        sym = "?"
        # Only try to symbolise the native libraries we care about; the JIT regions have no symbols.
        if lib.endswith(".so") or ".so." in lib:
            try:
                r = subprocess.run(["addr2line", "-f", "-C", "-e", lib, hex(fileoff)],
                                   capture_output=True, text=True, timeout=10)
                sym = r.stdout.strip().replace("\n", " @ ")[:88] or "?"
            except Exception:
                pass
        cache[key] = sym
    print("  %-9d %-52s %s" % (n, os.path.basename(lib)[:52], cache[key]))
PY
echo MALLOCCALLERS_DONE
