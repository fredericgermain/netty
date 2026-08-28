#!/bin/bash
# Verify the patched QUIC native actually lost its glibc-only DT_NEEDED entry.
#
# The build log is not evidence. The patchelf step in codec-native-quic/pom.xml has silently patched
# nothing and reported success twice before, once because it was bound to a phase where the .so did
# not exist yet and once because of a hardcoded path that hawtjni does not use. "Patched nothing" and
# "patched correctly" produce identical build output, so the only trustworthy check is to look at the
# ELF and then to load it.
#
# Both jars are compared side by side rather than checking the new one alone, because an absence of
# ld-linux in the new file only means something if it is present in the old one.
set -u

NEW=/home/fred/netty-quic/codec-native-quic/target/netty-codec-native-quic-4.2.18.Final-SNAPSHOT-linux-x86_64.jar
OLD=/home/fred/.m2/repository/io/netty/netty-codec-native-quic/4.2.18.Final-SNAPSHOT/netty-codec-native-quic-4.2.18.Final-SNAPSHOT-linux-x86_64.jar
WORK=/home/fred/quic-verify

rm -rf "$WORK"; mkdir -p "$WORK/new" "$WORK/old"
cd "$WORK/new" && unzip -q -o "$NEW" 2>/dev/null
cd "$WORK/old" && unzip -q -o "$OLD" 2>/dev/null

for tag in old new; do
  so=$(find "$WORK/$tag" -name "*.so" | head -1)
  echo "===== $tag: $(basename "$so") ($(stat -c%s "$so" 2>/dev/null) bytes)"
  if [ -z "$so" ]; then echo "  NO .so FOUND"; continue; fi
  echo "  -- DT_NEEDED:"
  readelf -d "$so" 2>/dev/null | grep NEEDED | sed 's/^/     /'
  # The whole point of the fix. musl satisfies these internally and never looks them up, but only for
  # names it reserves; ld-linux-x86-64.so.2 is not one of them and can never resolve.
  if readelf -d "$so" 2>/dev/null | grep -q "ld-linux"; then
    echo "  -- VERDICT: ld-linux STILL PRESENT, patch did not take"
  else
    echo "  -- VERDICT: no ld-linux entry"
  fi
  echo "  -- musl_compat symbols compiled in (expect >0 for the patched build):"
  nm -D "$so" 2>/dev/null | grep -cE "__getauxval|__xstat|secure_getenv" | sed 's/^/     matches: /'
done
echo VERIFY_DONE
