#!/bin/bash
# Build the replication USB key: a stock Ubuntu live ISO, plus a persistent BENCHDATA partition
# carrying everything the sweeps need.
#
#   scripts/usb-build.sh --iso ubuntu-26.04.1-desktop-amd64.iso --dev /dev/sdX --yes
#
# DESTRUCTIVE. Every byte of --dev is overwritten. It refuses a device that is not removable, is
# mounted, or was not named explicitly, and it has no default target.
#
# Why no remastered ISO: rebuilding a squashfs is a second thing that can silently differ between
# two boots, and the whole point of one key on two machines is that the environment is identical by
# construction. A stock ISO plus a data partition keeps the image byte-identical and puts everything
# variable in one place that can be inspected.
#
# Boot it with `toram` on the kernel command line so the session is RAM-resident and no state
# accumulates between the two machines. BENCHDATA stays on the key and is the only thing that
# persists, which is deliberate: it holds the raw output.

set -u
ISO="" ; DEV="" ; CONFIRM=0
REPO=$(cd "$(dirname "$0")/../.." && pwd)
WIFI_SRC="${WIFI_SRC:-}"
# An ssh public key so the booted machine can be driven from the other one. Public key material, so
# it is safe on removable media -- unlike wifi.conf, which is not. The default is this host's own
# key, because the useful direction is thor -> the machine under test: a session driven from its own
# keyboard puts a terminal and an input stack on the cores being measured. The 9380 standby kit
# installed authorized_keys on every boot for exactly this reason.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_fred_thor.pub}"

# The images the cells need. Saved from this host rather than pulled on the target, so the two
# machines run byte-identical images and neither depends on a registry mid-sweep.
#   temurin:21-jdk          glibc; the QUIC sweeps' default
#   temurin:21-jdk-alpine   musl; what the TCP and TLS sweeps have always used
#   iouring-control:latest  cell C's client, echo_bench_stock from pinned upstream SHAs. Build it
#                           with: docker build --network=host -t iouring-control:latest c-control/
IMAGES="${IMAGES:-eclipse-temurin:21-jdk eclipse-temurin:21-jdk-alpine iouring-control:latest}"
# No libsmbios-bin: it does not exist in Ubuntu 26.04, and the thermal mode now goes through
# /sys/firmware/acpi/platform_profile, which needs no package. openssh-server is here because
# usb-setup.sh's ssh step needs it offline, and iw because the regulatory-domain fix needs it --
# which is a deadlock otherwise: no iw until apt works, no apt until wi-fi works, and wi-fi may be
# what the regdomain is blocking.
DEBS="iw ethtool jq unzip openssh-server"

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;;
    --dev) DEV=$2; shift 2 ;;
    --wifi) WIFI_SRC=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --no-ssh-key) SSH_KEY=""; shift ;;
    --yes) CONFIRM=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "FATAL: $*" >&2; exit 1; }
[ -n "$ISO" ] || die "--iso is required"
[ -n "$DEV" ] || die "--dev is required; there is no default"
[ -f "$ISO" ] || die "ISO not found: $ISO"
[ -b "$DEV" ] || die "not a block device: $DEV"

base=$(basename "$DEV")
base=${base%%[0-9]*}
[ "$(cat "/sys/block/$base/removable" 2>/dev/null)" = 1 ] ||
  die "$DEV ($base) is not removable. Refusing: this script overwrites the whole device."
mount | grep -q "^$DEV" && die "$DEV has mounted partitions; unmount them first"

echo "== target"
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINT "$DEV"
# sysfs first, blockdev second. `blockdev --getsize64` needs to open the device, so it needs root --
# which would make the dry run, the whole point of which is to check the target BEFORE running this
# as root, fail with an arithmetic error on an empty string. /sys/block/<dev>/size is world
# readable and is in 512-byte sectors.
size_bytes=""
if [ -r "/sys/block/$base/size" ]; then
  size_bytes=$(( $(cat "/sys/block/$base/size") * 512 ))
else
  size_bytes=$(blockdev --getsize64 "$DEV" 2>/dev/null)
fi
[ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ] 2>/dev/null ||
  die "could not read the size of $DEV (tried /sys/block/$base/size and blockdev)"
size_gb=$(( size_bytes / 1000000000 ))
iso_gb=$(( $(stat -c %s "$ISO") / 1000000000 ))
echo "   device ${size_gb} GB, iso ${iso_gb} GB, leaving about $(( size_gb - iso_gb - 1 )) GB for BENCHDATA"
[ $(( size_gb - iso_gb )) -ge 8 ] || die "need at least 8 GB free after the ISO for images and results"

if [ "$CONFIRM" != 1 ]; then
  echo
  echo "Nothing was written. Re-run with --yes to overwrite $DEV entirely."
  exit 0
fi

# ---------------------------------------------------------------- the ISO
echo "== writing the iso (this takes a while)"
dd if="$ISO" of="$DEV" bs=4M conv=fsync status=progress || die "dd failed"
sync

# ---------------------------------------------------------------- the data partition
#
# Ubuntu's desktop ISO is GPT isohybrid, so after dd the trailing space is unallocated and a further
# partition can be added without touching what the ISO wrote. sgdisk moves the backup GPT header to
# the real end of the device first, which dd left pointing at the end of the ISO image.
echo "== adding BENCHDATA"
sgdisk --move-second-header "$DEV" >/dev/null 2>&1 || true
sgdisk --new=0:0:0 --change-name=0:BENCHDATA "$DEV" >/dev/null || die "sgdisk could not add a partition"
partprobe "$DEV" 2>/dev/null || true
sleep 2
part=$(lsblk -lno NAME,PARTLABEL "$DEV" | awk '$2 == "BENCHDATA" {print "/dev/"$1; exit}')
[ -n "$part" ] || die "the new partition did not appear; check lsblk $DEV"
mkfs.ext4 -q -L BENCHDATA "$part" || die "mkfs failed on $part"

MNT=$(mktemp -d)
mount "$part" "$MNT" || die "could not mount $part"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
mkdir -p "$MNT"/{scripts,images,debs,results,docker}

# ---------------------------------------------------------------- contents
echo "== scripts"
for f in topology.sh calibrate.sh bench-usb.sh usb-setup.sh hwinfo.sh wifi.conf.example; do
  cp "$REPO/benchmark-report/scripts/$f" "$MNT/scripts/" || die "missing scripts/$f"
done
# lib.sh is sourced by the sweeps and by calibrate.sh, and it expects ../scripts/topology.sh
# alongside it, so the layout on the key mirrors the repo rather than flattening it.
mkdir -p "$MNT/quic"
cp "$REPO/benchmark-report/quic/"*.sh "$MNT/quic/"
cp "$REPO/benchmark-report/REPLICATION.md" "$MNT/"
chmod +x "$MNT"/scripts/*.sh

echo "== wi-fi config"
if [ -n "$WIFI_SRC" ] && [ -f "$WIFI_SRC" ]; then
  install -m 600 "$WIFI_SRC" "$MNT/wifi.conf"
  echo "   wifi.conf installed from $WIFI_SRC, mode 600"
else
  cp "$REPO/benchmark-report/scripts/wifi.conf.example" "$MNT/wifi.conf.example"
  echo "   NO wifi.conf. Copy wifi.conf.example to wifi.conf on the key and fill it in, or the"
  echo "   live session will come up with no network and usb-setup.sh will stop there."
fi

echo "== ssh key"
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  install -m 644 "$SSH_KEY" "$MNT/authorized_keys"
  echo "   authorized_keys from $SSH_KEY ($(awk '{print $1, $3}' "$SSH_KEY"))"
else
  echo "   no ssh key, so the booted machine can only be driven at its own keyboard."
  echo "   Pass --ssh-key <path to a .pub>, or --no-ssh-key to mean it."
fi

echo "== jar"
JAR_SRC="$REPO/loadtest/target/loadtest.jar"
if [ -f "$JAR_SRC" ]; then
  cp "$JAR_SRC" "$MNT/loadtest.jar"
  echo "   $(stat -c %s "$MNT/loadtest.jar") bytes"
else
  echo "   MISSING $JAR_SRC"
  echo "   build it: ./mvnw -q -pl loadtest -am package"
fi

echo "== images"
if docker info >/dev/null 2>&1; then
  for ref in $IMAGES; do
    name=$(echo "$ref" | tr '/:' '--')
    if docker image inspect "$ref" >/dev/null 2>&1; then
      docker save "$ref" -o "$MNT/images/$name.tar" && echo "$ref" > "$MNT/images/$name.ref" &&
        echo "   saved $ref ($(( $(stat -c %s "$MNT/images/$name.tar") / 1048576 )) MB)"
    else
      echo "   MISSING locally: $ref -- docker pull it first, or the target has to pull it over wi-fi"
    fi
  done
  # Cell C cannot run without iouring-control, and a key that is missing it fails on the second
  # machine rather than here, which is the expensive place to find out.
  if ! docker image inspect iouring-control:latest >/dev/null 2>&1; then
    echo "   WARNING: iouring-control:latest is not built, so cell C has no client."
    echo "            docker build --network=host -t iouring-control:latest \\"
    echo "              $REPO/benchmark-report/c-control/"
  fi
else
  echo "   docker is not running on this host, so no images were saved."
  echo "   Start it and re-run, or the live session pulls ~800 MB over wi-fi."
fi

echo "== debs (offline fallback)"
# `apt-get install --download-only` rather than `apt-get download`, because the latter resolves no
# dependencies: it fetched openssh-server's .deb and none of the libraries it needs, which is an
# offline fallback that cannot actually install anything. --download-only pulls the whole closure.
#
# This only works because this host and the target image are the same release. Checked rather than
# assumed -- debs from a different release would install and then break in ways that look like
# benchmark noise.
#
# Known limit: --download-only fetches what THIS host would need to install, so a dependency already
# present here but absent from the live image is not staged. It is why openssh-server came with its
# whole closure (nothing ssh-related is installed on thor) while jq's libraries did not. The offline
# path stays a fallback for that reason; the ones that matter are iw, for the regulatory-domain
# deadlock, and openssh-server, and both are complete.
host_rel=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
iso_rel=$(basename "$ISO" | grep -oE '[0-9]{2}\.[0-9]{2}' | head -1)
if [ -z "$host_rel" ]; then
  echo "   skipped: cannot read this host's release from /etc/os-release"
elif ! grep -q "$iso_rel" /etc/os-release 2>/dev/null; then
  echo "   SKIPPED: this host is '$host_rel' but the ISO is $iso_rel. Debs from a different release"
  echo "            would install and then misbehave. The live session will use apt over wi-fi."
else
  mkdir -p "$MNT/debs/partial"
  if apt-get install -y --download-only --reinstall \
       -o Dir::Cache::archives="$MNT/debs" -o Debug::NoLocking=1 $DEBS >/dev/null 2>&1; then
    rmdir "$MNT/debs/partial" 2>/dev/null
    echo "   $(ls "$MNT"/debs/*.deb 2>/dev/null | wc -l) debs ($(du -sh "$MNT/debs" 2>/dev/null | cut -f1)), release $host_rel"
  else
    rmdir "$MNT/debs/partial" 2>/dev/null
    echo "   FAILED. Re-run just this part, or the live session needs the network for:"
    echo "            $DEBS"
    echo "   That is survivable but note the deadlock: the regulatory-domain fix needs iw, iw needs"
    echo "   apt, and apt needs the wi-fi the regdomain may be refusing."
  fi
fi

sync
cat <<EOF

== done
   Key: $DEV, data partition $part labelled BENCHDATA

   Boot it, appending to the kernel command line (press 'e' at the GRUB entry on the Ubuntu
   live menu):

       toram systemd.unit=multi-user.target

   toram makes the session RAM-resident. multi-user.target keeps GNOME from starting at all: a
   desktop session on the machine under test is resident memory, background services and wakeups
   on cores that are fully committed, and it does nothing for a benchmark.

   Then, in the live session:
     sudo mkdir -p /mnt/benchdata && sudo mount LABEL=BENCHDATA /mnt/benchdata
     sudo /mnt/benchdata/scripts/usb-setup.sh

   Test the whole path on the 9380 first. It establishes nothing about the transports but it is
   where the key's own problems will surface, and the clock cap for that machine has to be derived
   before any cell on it counts.
EOF
