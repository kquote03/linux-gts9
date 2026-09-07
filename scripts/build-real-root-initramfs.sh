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

# mmc block device letter/index isn't stable across boots (confirmed live
# this session, same instability class as UFS's sdX letters) -- the SD
# card has enumerated as both mmcblk0 and mmcblk1 depending on probe
# order. Try both, don't hardcode one.
REAL_ROOT_CANDIDATES=${REAL_ROOT_CANDIDATES:-"/dev/mmcblk1p1 /dev/mmcblk0p1"}
REAL_ROOT_FSTYPE=${REAL_ROOT_FSTYPE:-ext4}

echo "== staging real-root initramfs contents =="
mkdir -p "$workdir"/{bin,sbin,proc,sys,dev,tmp,mnt/newroot}
cp "$BUSYBOX_AARCH64_STATIC" "$workdir/bin/busybox"

for applet in sh mount umount cat echo ls dmesg sleep switch_root sync mkdir; do
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

REAL_ROOT_CANDIDATES="$REAL_ROOT_CANDIDATES"
REAL_ROOT_FSTYPE="$REAL_ROOT_FSTYPE"

# Bounded retry loop (mirrors the bring-up ramdisk's ttyGS0-wait pattern):
# mmc/UFS enumeration is asynchronous, confirmed this session to take a
# real, variable amount of time on this board. Try every candidate device
# each second rather than committing to one up front -- mmc block device
# naming isn't stable across boots (confirmed live this session).
REAL_ROOT_DEV=""
tries=0
while [ "\$tries" -lt 30 ]; do
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
