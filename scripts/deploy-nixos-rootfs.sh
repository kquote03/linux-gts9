#!/usr/bin/env bash
# Deploy the NixOS aarch64 rootfs (nixos/) to the SM-X716B, to one of
# three targets:
#
#   sd       -- partition a microSD from THIS PC (in a reader) and unpack
#               the rootfs tarball onto it. Stock Android on the
#               tablet's eMMC is not touched. Low risk.
#
#   twrp-sd  -- the microSD is already in the tablet's own slot; stream
#               the raw ext4 image onto its existing partition over adb
#               with the tablet in TWRP. Reuses the partition as-is (no
#               repartitioning) -- ERASES whatever rootfs/data is
#               currently on that card, but stock Android's internal
#               eMMC is untouched.
#
#   userdata -- with the tablet in TWRP, dd the raw ext4 rootfs image over
#               /dev/block/by-name/userdata. THIS ERASES STOCK ANDROID
#               /data. A real internal install.
#
# The boot bundle (boot/init_boot/vendor_boot/dtbo) is flashed separately
# with scripts/flash-boot-set.sh -- all three deploy targets carry the
# rootfs with filesystem label X716B_ROOT, which the bundle's initramfs
# finds.
#
# Usage:
#   scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device sd       DEV=/dev/sdX
#   scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device twrp-sd
#   scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device userdata
#
# Env overrides: TAR=<path to rootfs .tar.gz>, IMG=<path to ext4 .img>
# (default: built on demand via `nix build --impure ./nixos#...`).
#
# adb-over-stdin gotcha (confirmed live on this tablet's TWRP): its
# toybox `dd` fails `read error: Bad address` on stdin at bs=1M or
# larger when the input is the adb pipe (not a real file) -- a test
# file round-tripped byte-for-byte at bs=64k but not at bs=1M/8M. Every
# `adb shell dd ... < file` below uses bs=64k for exactly this reason.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

label=X716B_ROOT

usage() {
	sed -n '2,30p' "$0" >&2
	exit 1
}

if [ "${1:-}" != "--i-understand-this-writes-to-the-device" ]; then
	echo "Refusing to run without the acknowledgement flag." >&2
	usage
fi
shift

target=${1:-}
shift || true
for kv in "$@"; do
	case "$kv" in
		DEV=*) DEV=${kv#DEV=} ;;
		*) echo "unknown arg: $kv" >&2; usage ;;
	esac
done

build() {
	local attr=$1
	if command -v nix >/dev/null; then
		nix build --impure --no-link --print-out-paths "./nixos#$attr"
	else
		echo "nix not found and no explicit path given for $attr" >&2
		exit 1
	fi
}

case "$target" in
sd)
	: "${DEV:?pass DEV=/dev/sdX (the spare card, will be ERASED)}"
	[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }
	case "$DEV" in /dev/sd[a-z]|/dev/mmcblk[0-9]|/dev/nvme[0-9]n[0-9]) ;; *)
		echo "refusing: $DEV does not look like a whole-disk node" >&2; exit 1 ;;
	esac
	tar=${TAR:-$(build packages.x86_64-linux.rootfs-tar)}
	echo "== rootfs tarball: $tar =="

	lsblk "$DEV" || true
	read -rp "ERASE $DEV and write the NixOS rootfs to it? [type ERASE] " a
	[ "$a" = ERASE ] || { echo aborted; exit 1; }

	sudo umount "${DEV}"* 2>/dev/null || true
	sudo sgdisk --zap-all "$DEV"
	sudo sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"$label" "$DEV"
	sudo partprobe "$DEV"; sleep 1
	part="${DEV}1"; [ -b "${DEV}p1" ] && part="${DEV}p1"
	sudo mkfs.ext4 -F -L "$label" "$part"

	mnt=$(mktemp -d)
	sudo mount "$part" "$mnt"
	echo "== unpacking rootfs (sudo tar) =="
	sudo tar --numeric-owner -xzf "$tar" -C "$mnt"
	sync
	sudo umount "$mnt"; rmdir "$mnt"
	echo "== done. Card labelled $label. Now flash the boot bundle with scripts/flash-boot-set.sh =="
	;;

twrp-sd)
	if ! adb get-state 2>/dev/null | grep -q recovery; then
		echo "device is not in recovery (TWRP) mode -- aborting" >&2
		exit 1
	fi
	# This device has no internal eMMC -- any mmcblk* is the removable
	# card in the tray. Prefer its first partition (reuse it as-is);
	# fall back to the whole disk if unpartitioned. Parsed on the PC
	# side (not a remote awk one-liner) to dodge TWRP toybox awk regex
	# quirks.
	partitions=$(adb shell cat /proc/partitions | tr -d '\r')
	sddev=$(echo "$partitions" | grep -oE 'mmcblk[0-9]+$' | head -1)
	: "${sddev:?no mmcblk* device found in /proc/partitions -- is the card seated?}"
	sdpart=$(echo "$partitions" | grep -oE "${sddev}p1\$" | head -1)
	target_dev="/dev/block/${sdpart:-$sddev}"
	echo "== SD card: /dev/block/$sddev, target partition: $target_dev =="
	adb shell "cat /proc/partitions" | grep -E "$sddev"

	cat >&2 <<EOF
=========================  DESTRUCTIVE  =========================
 This writes the NixOS rootfs image directly over $target_dev,
 ERASING whatever is currently on that microSD card. Stock
 Android's internal storage is not touched.
===============================================================
EOF
	read -rp "Type ERASE to proceed: " a
	[ "$a" = ERASE ] || { echo aborted; exit 1; }

	img=${IMG:-$(build packages.x86_64-linux.rootfs-image)}
	echo "== rootfs image: $img ($(stat -c%s "$img") bytes) =="

	adb shell "umount $target_dev 2>/dev/null; umount /external_sd 2>/dev/null; true"
	echo "== streaming image to $target_dev (several minutes over USB) =="
	adb shell "dd of=$target_dev bs=64k" < "$img"
	adb shell sync
	echo "== NOT running TWRP's on-device e2fsck/resize2fs: confirmed live that its"
	echo "   bundled e2fsprogs 1.45 (~2019) cannot even parse the superblock this"
	echo "   image's modern mke2fs writes (\"has unsupported feature(s)\") -- a false"
	echo "   alarm, not corruption, but the same antique resize2fs would likely"
	echo "   mis-handle those feature bits too. fileSystems.\"/\".autoResize in"
	echo "   nixos/modules/x716b-hardware.nix grows it on first real boot instead,"
	echo "   using the matching e2fsprogs in the NixOS closure itself."
	echo "== done. Flash the boot bundle with scripts/flash-boot-set.sh, then reboot to system. =="
	;;

userdata)
	cat >&2 <<'EOF'
=========================  DESTRUCTIVE  =========================
 This writes the NixOS rootfs image directly over
 /dev/block/by-name/userdata and ERASES STOCK ANDROID /data
 (accounts, apps, internal storage). There is no undo.

 Rollback: restore a TWRP nandroid backup of `userdata`, or
 reflash stock firmware with Odin.

 Requirements: tablet in TWRP, `adb devices` shows it in
 `recovery` mode, and you have a fresh `userdata` backup pulled
 to this PC.
===============================================================
EOF
	if ! adb get-state 2>/dev/null | grep -q recovery; then
		echo "device is not in recovery (TWRP) mode -- aborting" >&2
		exit 1
	fi
	read -rp "Type ERASE-USERDATA to proceed: " a
	[ "$a" = ERASE-USERDATA ] || { echo aborted; exit 1; }

	img=${IMG:-$(build packages.x86_64-linux.rootfs-image)}
	echo "== rootfs image: $img ($(stat -c%s "$img") bytes) =="

	adb shell 'umount /data 2>/dev/null; umount /dev/block/by-name/userdata 2>/dev/null; true'
	echo "== streaming image to /dev/block/by-name/userdata (this takes a while) =="
	# bs=64k, not a larger block: TWRP's toybox dd reading stdin from the adb
	# pipe fails "read error: Bad address" at bs=1M+ (confirmed live) -- 64k
	# round-trips a test file byte-for-byte. No conv=fsync for the same
	# reason; a plain `sync` after covers it. The image already carries the
	# X716B_ROOT label (nixos/modules/rootfs-image.nix's volumeLabel), so no
	# on-device e2label -- TWRP's toybox doesn't have one anyway.
	adb shell 'dd of=/dev/block/by-name/userdata bs=64k' < "$img"
	adb shell sync
	echo "== NOT running TWRP's on-device e2fsck/resize2fs -- see the twrp-sd"
	echo "   target's comment above; fileSystems.\"/\".autoResize grows it on"
	echo "   first real boot using the NixOS closure's own e2fsprogs instead."
	echo "== done. Flash the boot bundle with scripts/flash-boot-set.sh, then reboot to system. =="
	;;

*)
	usage
	;;
esac
