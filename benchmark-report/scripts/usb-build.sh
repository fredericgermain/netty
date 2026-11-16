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

# The images the cells need. Saved from this host rather than pulled on the target, so the two
# machines run byte-identical images and neither depends on a registry mid-sweep.
#   temurin:21-jdk         glibc; the QUIC sweeps' default
#   temurin:21-jdk-alpine  musl; what the TCP and TLS sweeps have always used
#   bench-cclient:local    the C client for cell C, built from c-control/Dockerfile
IMAGES="${IMAGES:-eclipse-temurin:21-jdk eclipse-temurin:21-jdk-alpine}"
DEBS="libsmbios-bin iw ethtool jq unzip"

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO=$2; shift 2 ;;
    --dev) DEV=$2; shift 2 ;;
    --wifi) WIFI_SRC=$2; shift 2 ;;
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
size_gb=$(( $(blockdev --getsize64 "$DEV") / 1000000000 ))
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
for f in topology.sh calibrate.sh bench-usb.sh usb-setup.sh wifi.conf.example; do
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
  # Cell C needs the C client. It is built here rather than pulled, so record how.
  if [ -f "$REPO/benchmark-report/c-control/Dockerfile" ]; then
    echo "   note: cell C's C client image builds from benchmark-report/c-control/Dockerfile;"
    echo "         build and add it with IMAGES=\"... bench-cclient:local\" once it exists locally"
  fi
else
  echo "   docker is not running on this host, so no images were saved."
  echo "   Start it and re-run, or the live session pulls ~800 MB over wi-fi."
fi

echo "== debs (offline fallback)"
# Best effort, and deliberately only a fallback: apt-get download does not resolve dependencies, so
# a package needing new libs will still want the network. The primary path is wi-fi plus apt, which
# is why usb-setup.sh brings the link up before it installs anything.
( cd "$MNT/debs" && apt-get download $DEBS >/dev/null 2>&1 ) &&
  echo "   $(ls "$MNT"/debs/*.deb 2>/dev/null | wc -l) debs" ||
  echo "   none downloaded; the live session will need the network for packages"

sync
cat <<EOF

== done
   Key: $DEV, data partition $part labelled BENCHDATA

   Boot it, adding 'toram' to the kernel command line (press 'e' at the GRUB entry on the
   Ubuntu live menu and append it) so the session is RAM-resident.

   Then, in the live session:
     sudo mkdir -p /mnt/benchdata && sudo mount LABEL=BENCHDATA /mnt/benchdata
     sudo /mnt/benchdata/scripts/usb-setup.sh

   Test the whole path on the 9380 first. It establishes nothing about the transports but it is
   where the key's own problems will surface, and the clock cap for that machine has to be derived
   before any cell on it counts.
EOF
