#!/bin/bash
# Bring a freshly booted live session up to a state where it can run the replication sweeps.
# Run as root inside the live session, from the CIDATA partition:
#
#   sudo /mnt/benchdata/scripts/usb-setup.sh
#
# Order is deliberate. Wi-Fi first, because package installation, result shipping and remote access
# all depend on it and a session that silently has no network wastes the whole boot. Then docker
# pointed at persistent storage, then the images, then the host tuning, then the readiness gate.
#
# Idempotent: safe to re-run after a failed step.

set -u
# Self-locating: this script lives at <data>/scripts/usb-setup.sh, so the data partition is its own
# grandparent directory. It used to hard-code /mnt/benchdata, which meant the operator had to mount
# the partition at exactly that path -- three commands typed at a bare tty on the machine under
# test. Now any mount point works, and `go` at the partition root makes it one line.
SELF_DATA=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
DATA="${DATA:-${SELF_DATA:-/mnt/benchdata}}"
WIFI_CONF="${WIFI_CONF:-$DATA/wifi.conf}"
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mBAD\033[0m  %s\n' "$1"; }
# warn was called in the package step before it existed, which on any machine missing linux-tools
# printed "warn: command not found" in place of the message. Found by reading this against the 9380
# standby kit's scripts rather than by running it.
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
die()  { printf '  \033[31mFATAL\033[0m %s\n' "$1"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

# ---------------------------------------------------------------- 0. the data partition
step "data partition"
if [ ! -d "$DATA" ] || ! mountpoint -q "$DATA"; then
  dev=$(blkid -L CIDATA 2>/dev/null)
  [ -n "$dev" ] || die "no partition labelled CIDATA found. usb-build.sh creates it."
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

# From sysfs, not from `iw`. This step runs before package installation by design, so it cannot
# assume `iw` is installed -- and if it were missing, deriving the interface would have failed and
# taken the whole wi-fi step with it, on a machine where finding that out costs a trip.
WDEV=$(for d in /sys/class/net/*/wireless; do [ -e "$d" ] && basename "$(dirname "$d")" && break; done)
[ -n "$WDEV" ] || WDEV=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
[ -n "$WDEV" ] || die "no wireless interface in /sys/class/net/*/wireless. Check: lspci -k | grep -A3 -i network"

# Firmware actually loaded, rather than merely a driver bound.
if dmesg 2>/dev/null | grep -qiE 'ath10k.*(failed|crashed|unsupported)'; then
  bad "ath10k reported a problem:"
  dmesg | grep -i ath10k | tail -5 | sed 's/^/       /'
else
  fw=$(dmesg 2>/dev/null | grep -oiE 'ath10k.*firmware ver [^ ]+' | tail -1)
  ok "${fw:-ath10k bound}, interface $WDEV"
fi

command -v rfkill >/dev/null 2>&1 && { rfkill unblock wifi 2>/dev/null || true; }
# The regulatory domain is not cosmetic here. thor associates on 5180 MHz (channel 36, UNII-1) and
# its regdomain reads 00; Intel tolerates that, but this QCA6174 is the card most likely to refuse a
# no-IR channel under the world domain, which presents as "connected, no lease" or as silence while
# 2.4 GHz works. If `iw` is absent this is skipped and said so, rather than silently not happening.
if [ -n "${COUNTRY:-}" ]; then
  if command -v iw >/dev/null 2>&1; then
    iw reg set "$COUNTRY" 2>/dev/null && ok "regulatory domain $COUNTRY"
  else
    bad "iw not installed, regulatory domain left at $(cat /sys/module/cfg80211/parameters/ieee80211_regdom 2>/dev/null || echo unknown); 5 GHz association may fail"
  fi
fi

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
[ -n "$ip4" ] || { bad "no IPv4 lease after 30s; carrier=$(cat /sys/class/net/$WDEV/carrier 2>/dev/null || echo ?), operstate=$(cat /sys/class/net/$WDEV/operstate 2>/dev/null || echo ?)"; die "wi-fi did not come up; fix before measuring, results cannot leave this session without it"; }
if command -v iw >/dev/null 2>&1; then
  ok "$WDEV has $ip4, AP $(iw dev "$WDEV" link | awk '/Connected to/ {print $3}'), $(iw dev "$WDEV" link | awk '/freq/ {print $2" MHz"}')"
else
  ok "$WDEV has $ip4 (install iw for AP and frequency detail)"
fi

# Powersave off at the driver level too, independent of what NetworkManager believes.
if command -v iw >/dev/null 2>&1; then
  iw dev "$WDEV" set power_save off 2>/dev/null && ok "power_save off on $WDEV" || bad "could not disable power_save"
else
  bad "iw not installed yet; power_save not disabled. Re-run this script after the package step."
fi

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

# ---------------------------------------------------------------- 1b. ssh, so the machine can be
# driven from elsewhere
#
# This exists because of the 9380 standby kit, whose setup-live.sh installed authorized_keys and
# started sshd on every boot, and whose abrun.sh brought the network up only AFTER the last measured
# window. The point is not convenience: a session driven from its own keyboard means a shell, a
# terminal emulator and an input stack live on the cores under test. Driving it over ssh from the
# other machine moves all of that off the host being measured.
step "ssh"
if [ -f "$DATA/authorized_keys" ]; then
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    if ls "$DATA"/debs/openssh-server*.deb >/dev/null 2>&1; then
      dpkg -i "$DATA"/debs/openssh-server*.deb >/dev/null 2>&1 || true
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
    fi
  fi
  if [ -x /usr/sbin/sshd ]; then
    luser=$(logname 2>/dev/null || echo ubuntu)
    lhome=$(getent passwd "$luser" | cut -d: -f6)
    [ -n "$lhome" ] || lhome=/root
    install -d -m 700 -o "$luser" -g "$luser" "$lhome/.ssh" 2>/dev/null ||
      install -d -m 700 "$lhome/.ssh"
    install -m 600 -o "$luser" -g "$luser" "$DATA/authorized_keys" "$lhome/.ssh/authorized_keys" 2>/dev/null ||
      install -m 600 "$DATA/authorized_keys" "$lhome/.ssh/authorized_keys"
    systemctl enable --now ssh >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null
    if systemctl is-active ssh >/dev/null 2>&1 || pgrep -x sshd >/dev/null 2>&1; then
      ok "sshd running, key installed for $luser -- ssh $luser@${ip4%%/*}"
    else
      bad "sshd did not start; you will have to drive this machine at its own keyboard"
    fi
  else
    bad "openssh-server unavailable, no remote access"
  fi
else
  warn "no $DATA/authorized_keys, so no ssh. Pass one to usb-build.sh to drive this machine remotely"
fi

# ---------------------------------------------------------------- 1c. quiet the devices nobody is
# measuring
#
# Straight from the standby kit's quiet.sh, which found that Alpine shipped no udev rules for USB
# runtime power management and that the fingerprint reader and the stick's own SCSI disk therefore
# held the USB controller awake -- PC10 residency went from 0% to 92% once they were released.
#
# For a CPU-bound throughput benchmark deep package C-states are not the goal, but the interrupt
# sources are the same ones, and they are the same on both machines only if both are quieted. What
# is left awake is recorded either way, because a device that will not suspend is a fact about the
# run and not something to discover afterwards.
step "device quiet"
for f in /sys/bus/usb/devices/*/power/control /sys/bus/scsi/devices/*/power/control; do
  [ -w "$f" ] && echo auto > "$f" 2>/dev/null
done
awake=$(for d in /sys/bus/usb/devices/*; do
          [ -f "$d/product" ] || continue
          [ "$(cat "$d/power/runtime_status" 2>/dev/null)" = suspended ] && continue
          printf '%s(%s) ' "$(basename "$d")" "$(tr -d '\n' < "$d/product")"
        done)
if [ -n "$awake" ]; then
  warn "usb devices not suspended: $awake"
else
  ok "all usb devices suspended"
fi
# The key itself is necessarily awake -- it is the root filesystem's source and docker's data-root.
# That is why lib.sh measures a per-cell usbDelta rather than pretending the key is out of the way.
ok "recorded; lib.sh measures the key's write delta per cell"

# ---------------------------------------------------------------- 1d. what this machine is
#
# Before any cell, not after. REPLICATION.md compares two machines and claims only the hardware
# differs; that is checkable only if each machine's parts and BIOS state are on the record. BIOSHASH
# changes if any BIOS setting differs, which is the guard against comparing across a settings change
# nobody remembers making.
step "hardware and BIOS record"
if [ -x "$DATA/scripts/hwinfo.sh" ]; then
  mkdir -p "$DATA/results"
  hw="$DATA/results/hwinfo-$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr ' ' '-')-$(date -u +%Y%m%dT%H%M%SZ).txt"
  sh "$DATA/scripts/hwinfo.sh" > "$hw" 2>&1
  ok "$(basename "$hw")"
  grep -E '^(HWSUM|BIOSHASH|bios:|memory)' "$hw" | sed 's/^/       /'
else
  bad "scripts/hwinfo.sh missing from the key; the hardware this ran on will not be on the record"
fi

# ---------------------------------------------------------------- 2. packages
step "packages"
# libsmbios-bin is deliberately absent: it does not exist in Ubuntu 26.04, and the thermal mode is
# now set through /sys/firmware/acpi/platform_profile, which needs no package at all. Asking for it
# here would have failed the package step on every boot of this image.
need="iw ethtool jq unzip"
optional="linux-tools-common linux-tools-generic"
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
for p in $optional; do dpkg -s "$p" >/dev/null 2>&1 && ok "$p (optional)" || warn "$p absent; perf profiling unavailable, anchor cells unaffected"; done
# The thermal lever, which has to exist or the two machines cannot be put in the same thermal mode
# and the stock curve leaves the fans at 0 RPM until about 97 C. It is sysfs, not a package: see the
# note in bench-usb.sh. Verified on thor that writing platform_profile drives the same Dell BIOS
# attribute libsmbios used to set.
if [ -r /sys/firmware/acpi/platform_profile ]; then
  ok "platform_profile available: $(cat /sys/firmware/acpi/platform_profile) of [$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)]"
elif command -v smbios-thermal-ctl >/dev/null 2>&1; then
  ok "smbios-thermal-ctl available (older path; platform_profile absent)"
else
  bad "no thermal lever: neither /sys/firmware/acpi/platform_profile nor smbios-thermal-ctl. The two machines cannot be put in the same thermal mode"
fi

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
