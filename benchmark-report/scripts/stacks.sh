#!/bin/bash
# Name the Java frames that end in a direct-buffer zeroing, per transport.
#
# Unsafe_SetMemory0 is 100% of Copy::fill_to_memory_atomic, and that is what zeroing freshly
# allocated direct memory looks like. io_uring reaches it 2.3x more often per request than epoll at
# 256 KB, which is the same story the kernel frames tell (do_user_addr_fault, clear_page_erms,
# page_counter_try_charge). The question this answers is WHICH netty call site is allocating.
set -u
cd /home/fred/tls-matrix/bigprof || exit 1
for f in epoll-client io_uring-client io_uring-server epoll-server; do
  echo "===== $f"
  grep 'Unsafe_SetMemory0' "$f.collapsed" | while read -r line; do
    cnt=${line##* }
    stack=${line% *}
    echo "$cnt|$stack"
  done | sort -t'|' -k1 -rn | head -2 | while IFS='|' read -r cnt stack; do
    echo "  [$cnt samples]"
    echo "$stack" | tr ';' '\n' | grep -E 'netty|java|jdk' | tail -12 | sed 's/^/     /'
  done
done
