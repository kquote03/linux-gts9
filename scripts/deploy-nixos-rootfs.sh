#!/usr/bin/env bash
# Deploy the NixOS aarch64 rootfs (nixos/) to the SM-X716B, to one of two
# targets:
#
#   sd       -- partition a microSD from THIS PC and unpack the rootfs
#               tarball onto it. Stock Android on the tablet's eMMC is not
#               touched. Low risk.
#
#   userdata -- with the tablet in TWRP, dd the raw ext4 rootfs image over
#               /dev/block/by-name/userdata. THIS ERASES STOCK ANDROID
#               /data. A real internal install.
#
# The boot bundle (boot/init_boot/vendor_boot/dtbo) is flashed separately
# with scripts/flash-boot-set.sh -- both deploy targets carry the rootfs
# with filesystem label X716B_ROOT, which the bundle's initramfs finds.
#
# Usage:
#   scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device sd       DEV=/dev/sdX
#   scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device userdata
#
# Env overrides: TAR=<path to rootfs .tar.gz>, IMG=<path to ext4 .img>
# (default: built on demand via `nix build --impure ./nixos#...`).
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
	adb shell 'dd of=/dev/block/by-name/userdata bs=8M conv=fsync' < "$img"
	echo "== labelling + growing the filesystem =="
	adb shell 'e2fsck -fy /dev/block/by-name/userdata || true'
	adb shell "e2label /dev/block/by-name/userdata $label"
	adb shell 'resize2fs /dev/block/by-name/userdata'
	echo "== done. Flash the boot bundle with scripts/flash-boot-set.sh, then reboot to system. =="
	;;

*)
	usage
	;;
esac
