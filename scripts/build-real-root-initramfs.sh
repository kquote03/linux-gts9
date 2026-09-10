#!/usr/bin/env bash
# Build a minimal initramfs whose only job is to find the real root
# filesystem (the Alpine rootfs on the microSD card) and switch_root into
# it. Storage bring-up session, Phase E -- modeled directly on
# scripts/build-bringup-ramdisk.sh's structure (same static-busybox
# approach, same log()/retry-loop idioms), but with a genuine mount +
# switch_root instead of that script's "loop forever" placeholder.
#
# Why a real initramfs does the mount, rather than relying on the kernel's
# own root=/rootwait cmdline handling: mmc/UFS device enumeration is
# asynchronous (confirmed this session -- both took real, variable time to
# probe on this board), and a bounded retry loop here is simpler and more
# debuggable over the USB serial console than tuning rootwait/rootdelay
# blindly. The scripts/build-android-v4-bundle.sh cmdline's root=/rootfstype=
# (added this same session) are for documentation/tooling consistency, not
# actually consumed by the kernel's own root-mount code -- this script's
# /init is what really does it.
#
# Must run inside `nix-shell` (shell.nix), same BUSYBOX_AARCH64_STATIC
# requirement as build-bringup-ramdisk.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ -z "${BUSYBOX_AARCH64_STATIC:-}" ]; then
	echo "BUSYBOX_AARCH64_STATIC not set -- run this inside nix-shell" >&2
	exit 1
fi

# The real root is found by FILESYSTEM LABEL first (X716B_ROOT), so one
# initramfs serves every deploy target -- the microSD partition and the
# NixOS-on-userdata image both just carry that label (see nixos/). The
# device-node list is the fallback for the older Fedora microSD, whose
# root partition may be unlabelled: mmc block index isn't stable across
# boots (confirmed live -- the SD card has come up as both mmcblk0 and
# mmcblk1), so try both.
REAL_ROOT_LABEL=${REAL_ROOT_LABEL:-X716B_ROOT}
REAL_ROOT_CANDIDATES=${REAL_ROOT_CANDIDATES:-"/dev/mmcblk1p1 /dev/mmcblk0p1"}
REAL_ROOT_FSTYPE=${REAL_ROOT_FSTYPE:-ext4}

echo "== staging real-root initramfs contents =="
mkdir -p "$workdir"/{bin,sbin,proc,sys,dev,tmp,mnt/newroot}
cp "$BUSYBOX_AARCH64_STATIC" "$workdir/bin/busybox"

# WiFi/BT/GPU firmware, embedded directly in the initramfs -- NOT just
# staged in the real rootfs's own /usr/lib/firmware. Confirmed live
# (gts9wifi-fedora pivot, Session 9, real dmesg timestamps): ath11k and
# the Adreno GPU driver are both built-in (not modular, matching this
# project's own established philosophy) and request their firmware
# during their own early PCI/platform probe -- which happens *before*
# this initramfs's own /init has found and mounted the real root
# filesystem below (firmware load attempted at dmesg timestamp
# [1.294542], real root not mounted until [1.326643] -- a genuine ~32ms
# boot-order race, not a placement bug in the real rootfs). Copying the
# same already-proven firmware files here, available immediately, is a
# smaller, more surgical fix than converting these drivers to loadable
# modules (gts9wifi-fedora's own approach, which sidesteps the same race
# by deferring their probe until after switch_root instead).
fwdir="$workdir/lib/firmware"
repo_root_for_fw=$(cd "$repo_root" && pwd)
mkdir -p "$fwdir"
if [ -d "$repo_root_for_fw/buildroot/firmware-overlay/lib/firmware" ]; then
	cp -a "$repo_root_for_fw/buildroot/firmware-overlay/lib/firmware/." "$fwdir/"
else
	echo "WARNING: buildroot/firmware-overlay not built -- run scripts/fetch-ath11k-firmware.sh first" >&2
fi
mkdir -p "$fwdir/qcom"
vfw="$repo_root_for_fw/vendor-firmware-dump/firmware"
for f in a740_zap.mdt a740_zap.b00 a740_zap.b01 a740_zap.b02 a740_sqe.fw gmu_gen70200.bin; do
	if [ -f "$vfw/$f" ]; then
		cp "$vfw/$f" "$fwdir/qcom/$f"
	else
		echo "WARNING: $vfw/$f not found -- GPU firmware will be incomplete" >&2
	fi
done

for applet in sh mount umount cat echo ls dmesg sleep switch_root sync mkdir \
	      findfs blkid; do
	ln -sf busybox "$workdir/bin/$applet"
done

cat > "$workdir/init" <<EOF
#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

log() {
	echo "\$1" > /dev/kmsg 2>/dev/null
	echo "\$1"
}

log "=== linux-tabs9-port real-root initramfs: userspace reached ==="

REAL_ROOT_LABEL="$REAL_ROOT_LABEL"
REAL_ROOT_CANDIDATES="$REAL_ROOT_CANDIDATES"
REAL_ROOT_FSTYPE="$REAL_ROOT_FSTYPE"

# Bounded retry loop (mirrors the bring-up ramdisk's ttyGS0-wait pattern):
# mmc/UFS enumeration is asynchronous, confirmed this session to take a
# real, variable amount of time on this board. Each second: first ask for
# the labelled filesystem (works for any deploy target), then fall back to
# the fixed device-node list -- mmc block naming isn't stable across boots.
REAL_ROOT_DEV=""
tries=0
while [ "\$tries" -lt 30 ]; do
	if [ -n "\$REAL_ROOT_LABEL" ]; then
		cand=\$(/bin/busybox findfs "LABEL=\$REAL_ROOT_LABEL" 2>/dev/null)
		if [ -n "\$cand" ] && [ -b "\$cand" ]; then
			REAL_ROOT_DEV="\$cand"
			break
		fi
	fi
	for dev in \$REAL_ROOT_CANDIDATES; do
		if [ -b "\$dev" ]; then
			REAL_ROOT_DEV="\$dev"
			break 2
		fi
	done
	/bin/busybox sleep 1
	tries=\$((tries + 1))
done

if [ -z "\$REAL_ROOT_DEV" ]; then
	log "=== none of [\$REAL_ROOT_CANDIDATES] appeared after \${tries}s -- cannot continue ==="
	log "=== dropping to an emergency shell on ttyGS0 instead of switch_root ==="
	while true; do
		/bin/busybox sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1
	done
fi
log "=== \$REAL_ROOT_DEV present after \${tries}s ==="

if ! /bin/busybox mount -t "\$REAL_ROOT_FSTYPE" -o rw "\$REAL_ROOT_DEV" /mnt/newroot; then
	log "=== mount of \$REAL_ROOT_DEV (\$REAL_ROOT_FSTYPE) FAILED -- emergency shell ==="
	while true; do
		/bin/busybox sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1
	done
fi

log "=== real root mounted, switch_root-ing into it ==="
/bin/busybox mkdir -p /mnt/newroot/proc /mnt/newroot/sys /mnt/newroot/dev
/bin/busybox mount --move /proc /mnt/newroot/proc
/bin/busybox mount --move /sys /mnt/newroot/sys
/bin/busybox mount --move /dev /mnt/newroot/dev

exec /bin/busybox switch_root /mnt/newroot /sbin/init
EOF
chmod +x "$workdir/init"

mkdir -p "$outdir"
out="$outdir/real-root-initramfs.cpio.gz"

echo "== building $out =="
( cd "$workdir" && find . | cpio -o -H newc ) | gzip -9 > "$out"

ls -la "$out"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
