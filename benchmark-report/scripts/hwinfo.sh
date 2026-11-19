#!/bin/sh
# hwinfo.sh -- what hardware and what BIOS state a run was taken on, in one record.
#
#   scripts/hwinfo.sh                 # to stdout
#   scripts/hwinfo.sh > results/hwinfo-$(hostname).txt
#
# Carried over, almost verbatim, from the XPS 13 9380 standby test kit
# (~/workspaces/fred/dell-xps-9380-standby/alpine-scripts/hwinfo.sh, 2026-09-23). It is here because
# REPLICATION.md's whole premise is "one key, two machines, only the hardware differs" -- and that
# claim is unverifiable unless the hardware is on the record. calibrate.sh fingerprints the
# software; this fingerprints the parts and the firmware.
#
# What earns its place for a throughput benchmark specifically:
#   * memory per module -- vendor, part, size, RANK and configured MT/s. Rank and speed move a
#     throughput number directly, and two laptops with "16 GB" are not therefore comparable.
#   * BIOSHASH -- an md5 over every dell-wmi-sysman attribute. It changes if any BIOS setting
#     changed between the two machines or between two runs on one machine, which is the cheapest
#     possible guard against comparing across a settings change nobody remembers making.
#   * HWSUM -- one line, suitable as a run label.
#
# Reads SMBIOS type 17 out of /sys/firmware/dmi/entries directly rather than calling dmidecode,
# because the original ran on an Alpine stick that had no dmidecode. Kept that way: it means this
# works on a minimal live session with nothing installed.
#
# The DEVICES line's PCI/USB ids are the 9380's parts. On another machine some read "no", which is
# itself the information wanted -- it says the two machines differ in what is fitted.
b(){ od -A n -t u1 -j $2 -N 1 "$1" | tr -d ' '; }                    # byte at offset
w(){ od -A n -t u2 -j $2 -N 2 "$1" | tr -d ' '; }                    # little-endian word
d(){ od -A n -t u4 -j $2 -N 4 "$1" | tr -d ' '; }                    # little-endian dword
s(){ [ "$3" -gt 0 ] 2>/dev/null || { echo "-"; return; }             # SMBIOS string number $3 of entry $1
     tail -c +$(( $2 + 1 )) "$1" | tr '\0' '\n' | sed -n "${3}p" | sed 's/ *$//'; }
jedec(){ case "$1" in 802C*|2C00*) echo Micron;; 80CE*|CE00*) echo Samsung;; 80AD*|AD00*) echo SK-Hynix;;
         859B*) echo Crucial;; 0198*|8198*) echo Kingston;; 04CB*|84CB*) echo A-DATA;; 04CD*|84CD*) echo G.Skill;;
         *) echo "$1";; esac; }
sum="HWSUM"
for e in /sys/firmware/dmi/entries/17-*; do
  r=$e/raw; [ -r $r ] || continue
  len=$(b $r 1); size=$(w $r 12)
  [ "$size" = 32767 ] && size=$(d $r 28)                               # extended size, MB
  loc=$(s $r $len $(b $r 16)); rank=$(( $(b $r 27) & 15 ))
  if [ "$size" = 0 ] || [ "$size" = 65535 ]; then
    echo "memory $loc: empty"; sum="$sum $(echo $loc | tr -d ' ')=empty"; continue
  fi
  manu=$(s $r $len $(b $r 23)); part=$(s $r $len $(b $r 26)); ser=$(s $r $len $(b $r 24))
  speed=$(w $r 21); cspeed=$( [ $len -gt 32 ] && w $r 32 || echo "?")
  echo "memory $loc: $(jedec "$manu") ($manu) part $part serial $ser ${size} MB rank $rank ${speed} MT/s (configured ${cspeed})"
  sum="$sum $(echo $loc | tr -d ' ')=$(jedec "$manu"):$part:${size}MB:r$rank"
done
n=0
for blk in /sys/block/*; do
  case $(basename $blk) in loop*|ram*|zram*|dm-*|sr*) continue;; esac
  dev=$blk/device; model=$(cat $dev/model 2>/dev/null || cat $dev/name 2>/dev/null); model=$(echo "$model" | sed "s/ *$//"); [ -n "$model" ] || continue   # eMMC: device/name
  fw=$(cat $dev/firmware_rev $dev/rev 2>/dev/null | head -1 | sed 's/ *$//'); ser=$(cat $dev/serial 2>/dev/null | sed 's/ *$//')
  gb=$(( $(cat $blk/size) / 2097152 )); rm=$(cat $blk/removable 2>/dev/null)
  echo "drive $(basename $blk): $model fw $fw serial $ser ${gb} GiB removable=$rm"
  [ "$rm" = 1 ] || { sum="$sum $(basename $blk)=$(echo $model | tr ' ' _):$fw"; n=$((n+1)); }
done
[ $n = 0 ] && sum="$sum drive=none"
# Devices the firmware exposed at boot, so a BIOS switch can be checked against what actually disappeared.
# DEVICES is a yes/no summary of the parts the BIOS can switch off; pci/usb lines are the full lists.
has_pci(){ grep -qx "$1" /tmp/.pciids 2>/dev/null; }
has_usb(){ grep -qx "$1" /tmp/.usbids 2>/dev/null; }
: > /tmp/.pciids; : > /tmp/.usbids
for d in /sys/bus/pci/devices/*; do
  id=$(cat $d/vendor | cut -c3-):$(cat $d/device | cut -c3-); echo $id >> /tmp/.pciids
  echo "pci $(basename $d | cut -c6-) $id $(basename "$(readlink $d/driver 2>/dev/null)" 2>/dev/null) $(cat $d/power_state 2>/dev/null)"
done
for d in /sys/bus/usb/devices/[0-9]-*; do
  [ -f $d/idVendor ] || continue; id=$(cat $d/idVendor):$(cat $d/idProduct); echo $id >> /tmp/.usbids
  echo "usb $(basename $d) $id $(cat $d/product 2>/dev/null | tr ' ' _)"
done
yn(){ "$@" && echo yes || echo no; }
echo "DEVICES wifi=$(yn has_pci 8086:06f0) bt=$(yn has_usb 8087:0026) cardreader=$(yn has_pci 10ec:5260) fingerprint=$(yn has_usb 27c6:533c) camera=$(yn has_usb 0c45:6d14) audio=$(yn has_pci 8086:06c8) thunderbolt=$(yn has_pci 8086:15eb) pci=$(wc -l < /tmp/.pciids | tr -d ' ') usb=$(wc -l < /tmp/.usbids | tr -d ' ')"
# BIOS settings through Dell's WMI interface (dell-wmi-sysman). All of them go to the log; BIOSDEV is the
# device-related subset, BIOSHASH changes whenever any setting changes.
modprobe dell-wmi-sysman 2>/dev/null; sleep 1
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
if [ -d $A ]; then
  : > /tmp/.bios
  for a in $A/*; do [ -r $a/current_value ] && echo "$(basename $a)=$(cat $a/current_value 2>/dev/null | tr -d '\n' | tr ' ' _)" >> /tmp/.bios; done
  sed 's/^/biosattr /' /tmp/.bios
  echo "BIOSDEV $(grep -iE '^[^=]*(camera|fingerprint|fprnt|sdcard|sd_card|cardread|audio|microph|speaker|wlan|wireless|bluetooth|bt|thunderbolt|tbt|usb|powershare|touch)[^=]*=' /tmp/.bios | tr '\n' ' ')"
  echo "BIOSHASH $(sort /tmp/.bios | md5sum | cut -c1-12) ($(wc -l < /tmp/.bios | tr -d ' ') settings)"
else
  echo "BIOSDEV unavailable (dell-wmi-sysman did not load)"
fi
echo "bios: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null) BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
for p in /sys/class/power_supply/*; do
  [ "$(cat $p/online 2>/dev/null)" = 1 ] && [ -f $p/voltage_now ] && [ "$(cat $p/type)" = USB ] && \
    echo "charger: $(basename $p) $(( $(cat $p/voltage_now) / 1000000 )) V $(( $(cat $p/current_max 2>/dev/null) / 1000 )) mA max"
done
bat=/sys/class/power_supply/BAT0; [ -d $bat ] && echo "battery: $(cat $bat/status) $(cat $bat/capacity)% $(cat $bat/voltage_now) uV"
echo "$sum"
