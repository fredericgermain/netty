#!/bin/bash
# Bring a freshly booted live session up to a state where it can run the replication sweeps.
# Run as root inside the live session, from the BENCHDATA partition:
#
#   sudo /mnt/benchdata/scripts/usb-setup.sh
#
# Order is deliberate. Wi-Fi first, because package installation, result shipping and remote access
# all depend on it and a session that silently has no network wastes the whole boot. Then docker
# pointed at persistent storage, then the images, then the host tuning, then the readiness gate.
#
# Idempotent: safe to re-run after a failed step.

set -u
DATA="${DATA:-/mnt/benchdata}"
WIFI_CONF="${WIFI_CONF:-$DATA/wifi.conf}"
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mBAD\033[0m  %s\n' "$1"; }
die()  { printf '  \033[31mFATAL\033[0m %s\n' "$1"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

# ---------------------------------------------------------------- 0. the data partition
step "data partition"
if [ ! -d "$DATA" ] || ! mountpoint -q "$DATA"; then
  dev=$(blkid -L BENCHDATA 2>/dev/null)
  [ -n "$dev" ] || die "no partition labelled BENCHDATA found. usb-build.sh creates it."
  mkdir -p "$DATA"
  mount "$dev" "$DATA" || die "could not mount $dev at $DATA"
fi
ok "$DATA mounted from $(findmnt -no SOURCE "$DATA"), $(df -h --output=avail "$DATA" | tail -1 | tr -d ' ') free"

# ---------------------------------------------------------------- 1. Wi-Fi
#
# The 9380 carries a Qualcomm Atheros QCA6174 driven by ath10k_pci, whose firmware ships in
# linux-firmware and is present on the Ubuntu live image. The failure modes worth checking are
# therefore not "is there a driver" but: rfkill soft-blocked after boot, a world regulatory domain
# that makes 5 GHz association fail silently, and firmware that loaded but crashed.
step "wi-fi"
[ -r "$WIFI_CONF" ] || die "no $WIFI_CONF (copy scripts/wifi.conf.example and fill it in)"
# shellcheck disable=SC1090
. "$WIFI_CONF"
[ -n "${SSID:-}" ] && [ -n "${PSK:-}" ] || die "$WIFI_CONF must set SSID and PSK"

WDEV=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
[ -n "$WDEV" ] || die "no wireless interface. Check: lspci -k | grep -A3 -i network"

# Firmware actually loaded, rather than merely a driver bound.
if dmesg 2>/dev/null | grep -qiE 'ath10k.*(failed|crashed|unsupported)'; then
  bad "ath10k reported a problem:"
  dmesg | grep -i ath10k | tail -5 | sed 's/^/       /'
else
  fw=$(dmesg 2>/dev/null | grep -oiE 'ath10k.*firmware ver [^ ]+' | tail -1)
  ok "${fw:-ath10k bound}, interface $WDEV"
fi

rfkill unblock wifi 2>/dev/null || true
[ -n "${COUNTRY:-}" ] && iw reg set "$COUNTRY" 2>/dev/null && ok "regulatory domain $COUNTRY"

# A NetworkManager keyfile rather than nmcli-on-the-command-line, so the PSK never reaches the
# process table or the shell history, and so the profile survives a NetworkManager restart.
profile=/etc/NetworkManager/system-connections/bench.nmconnection
umask 077
cat > "$profile" <<EOF
[connection]
id=bench
type=wifi
interface-name=$WDEV
autoconnect=true

[wifi]
mode=infrastructure
ssid=$SSID
${BSSID:+bssid=$BSSID}
# Random MACs change the DHCP lease between boots, which makes a results-shipping target that is
# pinned by address stop working halfway through a run.
cloned-mac-address=permanent
# Power saving on this link causes periodic wakeups that land on the cores under test. 2 = disable.
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
method=ignore
EOF
chmod 600 "$profile"
nmcli connection reload 2>/dev/null || true
nmcli connection up bench >/dev/null 2>&1 || nmcli device wifi connect "$SSID" password "$PSK" >/dev/null 2>&1 || true

# Wait for an address rather than assuming one. A live session that is "connected" with no lease
# looks fine in nmcli and cannot ship a result.
ip4=""
for _ in $(seq 1 30); do
  ip4=$(ip -4 -o addr show dev "$WDEV" 2>/dev/null | awk '{print $4; exit}')
  [ -n "$ip4" ] && break
  sleep 1
done
[ -n "$ip4" ] || { bad "associated=$(iw dev "$WDEV" link | head -1), no IPv4 lease after 30s"; die "wi-fi did not come up; fix before measuring, results cannot leave this session without it"; }
ok "$WDEV has $ip4, AP $(iw dev "$WDEV" link | awk '/Connected to/ {print $3}'), $(iw dev "$WDEV" link | awk '/freq/ {print $2" MHz"}')"

# Powersave off at the driver level too, independent of what NetworkManager believes.
iw dev "$WDEV" set power_save off 2>/dev/null && ok "power_save off on $WDEV" || bad "could not disable power_save"

# Steer the card's interrupts to the client side. With four physical cores and both sides pinned
# there is no idle core to park them on, so this is mitigation and not a fix: the client half of a
# comparison is the less sensitive one. Recorded either way, because an unsteerable IRQ is a fact
# about the run.
irq=$(awk -F: '/ath10k|iwlwifi|wlan/ {gsub(/ /,"",$1); print $1; exit}' /proc/interrupts)
if [ -n "$irq" ] && [ -w "/proc/irq/$irq/smp_affinity_list" ]; then
  echo "2,3,6,7" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null &&
    ok "wi-fi IRQ $irq steered to the client cpus" || bad "IRQ $irq affinity not writable (managed IRQ)"
else
  bad "could not identify a wi-fi IRQ to steer; record this run as unsteered"
fi

if [ -n "${RESULTS_REMOTE:-}" ]; then
  host=${RESULTS_REMOTE#*@}; host=${host%%:*}
  ping -c1 -W2 "$host" >/dev/null 2>&1 && ok "results target $host reachable" || bad "results target $host not reachable"
fi

# ---------------------------------------------------------------- 2. packages
step "packages"
need="libsmbios-bin iw ethtool jq unzip linux-tools-common"
missing=""
for p in $need; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
command -v docker >/dev/null 2>&1 || missing="$missing docker.io"
if [ -n "$missing" ]; then
  # Offline first: usb-build.sh stashes the debs so a session with no working link can still proceed
  # with everything except result shipping.
  if ls "$DATA"/debs/*.deb >/dev/null 2>&1; then
    dpkg -i "$DATA"/debs/*.deb >/dev/null 2>&1 || true
  fi
  still=""
  for p in $missing; do dpkg -s "$p" >/dev/null 2>&1 || still="$still $p"; done
  if [ -n "$still" ]; then
    apt-get update -qq 2>/dev/null
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $still >/dev/null 2>&1 || bad "apt could not install:$still"
  fi
fi
for p in $need; do dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || bad "$p MISSING"; done
# libsmbios is the only fan lever this hardware exposes, and without it both machines sit on the
# stock curve, which leaves the fans at 0 RPM until about 97 C.
command -v smbios-thermal-ctl >/dev/null 2>&1 && ok "smbios-thermal-ctl available" || bad "smbios-thermal-ctl MISSING: the two machines cannot be put in the same thermal mode"

# ---------------------------------------------------------------- 3. docker on persistent storage
#
# On a RAM-resident root, docker's graph would otherwise live in tmpfs, where every image layer is
# unevictable resident memory. On a 16 GB machine running a 2000-connection sweep that competes
# directly with the workload.
step "docker"
mkdir -p "$DATA/docker" "$DATA/results"
if [ "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" != "$DATA/docker" ]; then
  mkdir -p /etc/docker
  printf '{\n  "data-root": "%s"\n}\n' "$DATA/docker" > /etc/docker/daemon.json
  systemctl restart docker 2>/dev/null || systemctl start docker 2>/dev/null
  sleep 3
fi
root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
[ "$root" = "$DATA/docker" ] && ok "docker root $root (persistent, survives reboot)" || bad "docker root is $root, wanted $DATA/docker"

step "images and jar"
for t in "$DATA"/images/*.tar; do
  [ -e "$t" ] || { bad "no image tars in $DATA/images"; break; }
  name=$(basename "$t" .tar)
  if docker image inspect "$(cat "$DATA/images/$name.ref" 2>/dev/null || echo none)" >/dev/null 2>&1; then
    ok "$name already loaded"
  else
    docker load -q -i "$t" >/dev/null 2>&1 && ok "loaded $name" || bad "could not load $name"
  fi
done
[ -f "$DATA/loadtest.jar" ] && ok "loadtest.jar present ($(stat -c %s "$DATA/loadtest.jar") bytes)" || bad "loadtest.jar MISSING"

# ---------------------------------------------------------------- 4. tuning and the gate
step "host tuning"
"$DATA/scripts/bench-usb.sh" start || true

cat <<EOF

== next
   export RESULTS_DIR=$DATA/results JAR=$DATA/loadtest.jar
   $DATA/scripts/bench-usb.sh check          # must say READY
   $DATA/scripts/calibrate.sh \$(hostname)    # anchors, before any cell
EOF
