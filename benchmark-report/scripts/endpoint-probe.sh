#!/bin/bash
# What a real endpoint negotiates, captured so it can be cited.
#
# Usage: endpoint-probe.sh [host ...]        (default: the A7 endpoints)
#
# A7's original probe recorded only what the server selected, not what the client offered, which
# makes the result unreproducible: a server picks from the offer. So every arm here states its own
# offer, and two arms withhold the post-quantum group to show what the server falls back to.
# Nothing is timed -- this is a does-it-negotiate result.
set -u

HOSTS=("$@")
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=(s3.eu-west-1.amazonaws.com s3.us-east-1.amazonaws.com)

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

echo "date            $(date -Is)"
echo "client          $(openssl version)"
echo "client built    $(openssl version -a | sed -n 's/^built on: *//p')"
echo "host kernel     $(uname -r)"
echo

probe() {  # probe <host> <label> [groups]
  local host=$1 label=$2 groups=${3:-}
  local args=(-connect "$host:443" -servername "$host" -brief)
  [ -n "$groups" ] && args+=(-groups "$groups")
  printf '%-26s %-14s ' "$host" "$label"
  local out
  out=$(printf '' | timeout 20 openssl s_client "${args[@]}" 2>&1)
  if ! grep -q 'Protocol version' <<<"$out"; then
    echo "FAILED: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
    return
  fi
  # -brief writes its summary to stderr, and reports the group two different ways: "Negotiated
  # TLS1.3 group:" for a hybrid, "Peer Temp Key: X25519, 253 bits" for a classical curve. Reading
  # only the first prints an empty group for every non-PQ arm, which reads as "no group negotiated".
  awk '
    /^Protocol version:/        { p=$3 }
    /^Ciphersuite:/             { c=$2 }
    /^Negotiated TLS1.3 group:/ { g=$4 }
    /^Peer Temp Key:/           { t=$4; if (t == "ECDH,") t=$5; sub(/,$/, "", t) }
    /^Signature type:/          { s=$3 }
    END { printf "%-8s %-28s %-18s %s\n", p, c, (g != "" ? g : (t != "" ? t : "-")), (s == "" ? "-" : s) }
  ' <<<"$out"
}

echo "=== the client's own default offer"
echo "supported_groups as sent in this client's ClientHello:"
printf '' | timeout 20 openssl s_client -connect "${HOSTS[0]}:443" -servername "${HOSTS[0]}" \
  -trace 2>&1 | sed -n '/supported_groups/,/extension_type=session_ticket/p' | sed '$d' | sed 's/^ */  /'
echo

printf '%-26s %-14s %-8s %-28s %-18s %s\n' host offer version ciphersuite group sigalg
for h in "${HOSTS[@]}"; do
  probe "$h" default
  probe "$h" pq-first   "X25519MLKEM768:X25519:P-256"
  probe "$h" no-pq      "X25519:P-256"
  probe "$h" p256-only  "P-256"
done

# Is one probe enough? The recalled A7 result quoted a ciphersuite as if it were a property of the
# endpoint. Repeat the default arm and tally, keeping the server IP, because a name like this is many
# machines and the answer can differ per connection.
echo
echo "=== ${REPEAT:-10} repeats of the default arm against ${HOSTS[0]}, tallied"
for _ in $(seq 1 "${REPEAT:-10}"); do
  printf '' | timeout 20 openssl s_client -connect "${HOSTS[0]}:443" -servername "${HOSTS[0]}" \
    -brief 2>&1 | awk '
      /^Connecting to/            { ip=$3 }
      /^Ciphersuite:/             { c=$2 }
      /^Negotiated TLS1.3 group:/ { g=$4 }
      /^Peer Temp Key:/           { t=$4; if (t == "ECDH,") t=$5; sub(/,$/, "", t) }
      END { print ip, c, (g != "" ? g : t) }'
done | sort | uniq -c | sort -rn | sed 's/^/  /'

echo
echo PROBE_DONE
