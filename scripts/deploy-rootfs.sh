#!/usr/bin/env bash
# Deploy ANY of this port's rootfs builds (Fedora, Debian, NixOS, ...) to
# the SM-X716B, to one of three targets. Distro-agnostic: pass the built
# artifact explicitly (TAR= a .tar.gz directory dump, or IMG= a raw ext4
# image already labelled X716B_ROOT) -- this script only streams bytes to
# a partition, it has no idea what's inside them.
#
#   sd       -- partition a microSD from THIS PC (in a reader) and unpack
#               the rootfs tarball onto it. Stock Android on the
#               tablet's eMMC is not touched. Low risk. Needs TAR=.
#
#   twrp-sd  -- the microSD is already in the tablet's own slot; stream
#               the raw ext4 image onto its existing partition over adb
#               with the tablet in TWRP. Reuses the partition as-is (no
#               repartitioning) -- ERASES whatever rootfs/data is
#               currently on that card, but stock Android's internal
#               eMMC is untouched. Needs IMG=.
#
#   userdata -- with the tablet in TWRP, dd the raw ext4 rootfs image over
#               /dev/block/by-name/userdata. THIS ERASES STOCK ANDROID
#               /data. A real internal install. Needs IMG=.
#
# The boot bundle (boot/init_boot/vendor_boot/dtbo) is flashed separately
# with scripts/flash-boot-set.sh -- all three deploy targets carry the
# rootfs with filesystem label X716B_ROOT, which the bundle's initramfs
# (scripts/build-real-root-initramfs.sh) finds by that label first,
# regardless of which distro built it.
#
# Usage:
#   scripts/deploy-rootfs.sh --i-understand-this-writes-to-the-device sd       TAR=out/x716b-rootfs.tar.gz DEV=/dev/sdX
#   scripts/deploy-rootfs.sh --i-understand-this-writes-to-the-device twrp-sd  IMG=out/x716b-rootfs.img
#   scripts/deploy-rootfs.sh --i-understand-this-writes-to-the-device userdata IMG=out/x716b-rootfs.img
#
# Where to get TAR=/IMG= per distro:
#   - NixOS:  nix build --impure ./nixos#rootfs-tar   (or #rootfs-image)
#   - Fedora: scripts/build-fedora-rootfs.sh produces a rootfs directory;
#             tar it, or run scripts/build-rootfs-image.sh against it for
#             a raw .img.
#   - Debian: scripts/build-debian-rootfs.sh produces a rootfs directory;
#             same as Fedora above.
#
# For a raw ext4 image from a plain rootfs directory (Fedora/Debian, not
# NixOS which builds its own via nixos/packages/rootfs-image.nix):
#   scripts/build-rootfs-image.sh <rootfs-dir> <out.img> [size-margin-MiB]
#
# adb-over-stdin gotcha (confirmed live on this tablet's TWRP): its
# toybox `dd` fails `read error: Bad address` on stdin at bs=1M or
# larger when the input is the adb pipe (not a real file) -- a test
# file round-tripped byte-for-byte at bs=64k but not at bs=1M/8M. Every
# `adb shell dd ... < file` below uses bs=64k for exactly this reason.
#
# A second, unrelated stdin gotcha, also confirmed live: every OTHER
# `adb shell ...` call in this script inherits this script's own stdin
# unless explicitly redirected -- when this script itself is invoked with
# a non-terminal stdin (piped input, a redirected file, run from an
# agent/CI harness), an earlier `adb shell cat /proc/partitions` silently
# consumes the line meant for the later `read -rp "Type ERASE..."`
# confirmation prompt, which then hits EOF and aborts under `set -e` with
# NO error message at all -- looks exactly like the script just silently
# quit right after printing the destructive-action banner. Every
# `adb shell`/`adb get-state` call below that isn't the actual `dd`
# stream redirects its own stdin from `/dev/null` for exactly this
# reason.
#
# Also confirmed live: do NOT run TWRP's own e2fsck/resize2fs against a
# raw image streamed onto a bigger partition. Its bundled e2fsprogs
# (1.45.4, ~2019) can't even parse the `orphan_file` feature a modern
# mke2fs writes ("has unsupported feature(s)") -- a false alarm, not
# corruption, but the same antique resize2fs would likely mis-handle
# those feature bits too. Let the rootfs itself grow to fill the
# partition on first real boot instead -- NixOS's
# `fileSystems."/".autoResize`, or the overlay's own
# `gts9wifi-grow-rootfs.service` on Fedora/Debian (both already wired up
# by their respective builders).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

label=X716B_ROOT

usage() {
	sed -n '2,40p' "$0" >&2
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
		TAR=*) TAR=${kv#TAR=} ;;
		IMG=*) IMG=${kv#IMG=} ;;
		*) echo "unknown arg: $kv" >&2; usage ;;
	esac
done

case "$target" in
sd)
	: "${TAR:?pass TAR=<path to a rootfs .tar.gz> -- see the header above for how to build one per distro}"
	[ -f "$TAR" ] || { echo "$TAR not found" >&2; exit 1; }
	: "${DEV:?pass DEV=/dev/sdX (the spare card, will be ERASED)}"
	[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }
	case "$DEV" in /dev/sd[a-z]|/dev/mmcblk[0-9]|/dev/nvme[0-9]n[0-9]) ;; *)
		echo "refusing: $DEV does not look like a whole-disk node" >&2; exit 1 ;;
	esac
	echo "== rootfs tarball: $TAR =="

	lsblk "$DEV" || true
	read -rp "ERASE $DEV and write this rootfs to it? [type ERASE] " a
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
	sudo tar --numeric-owner -xzf "$TAR" -C "$mnt"
	sync
	sudo umount "$mnt"; rmdir "$mnt"
	echo "== done. Card labelled $label. Now flash the boot bundle with scripts/flash-boot-set.sh =="
	;;

twrp-sd)
	: "${IMG:?pass IMG=<path to a raw ext4 .img, labelled $label> -- see the header above for how to build one per distro}"
	[ -f "$IMG" ] || { echo "$IMG not found" >&2; exit 1; }
	if ! adb get-state </dev/null 2>/dev/null | grep -q recovery; then
		echo "device is not in recovery (TWRP) mode -- aborting" >&2
		exit 1
	fi
	# This device has no internal eMMC -- any mmcblk* is the removable
	# card in the tray. Prefer its first partition (reuse it as-is);
	# fall back to the whole disk if unpartitioned. Parsed on the PC
	# side (not a remote awk one-liner) to dodge TWRP toybox awk regex
	# quirks.
	partitions=$(adb shell cat /proc/partitions </dev/null | tr -d '\r')
	sddev=$(echo "$partitions" | grep -oE 'mmcblk[0-9]+$' | head -1)
	: "${sddev:?no mmcblk* device found in /proc/partitions -- is the card seated?}"
	sdpart=$(echo "$partitions" | grep -oE "${sddev}p1\$" | head -1)
	target_dev="/dev/block/${sdpart:-$sddev}"
	echo "== SD card: /dev/block/$sddev, target partition: $target_dev =="
	adb shell "cat /proc/partitions" </dev/null | grep -E "$sddev"

	cat >&2 <<EOF
=========================  DESTRUCTIVE  =========================
 This writes the rootfs image directly over $target_dev,
 ERASING whatever is currently on that microSD card. Stock
 Android's internal storage is not touched.
===============================================================
EOF
	read -rp "Type ERASE to proceed: " a
	[ "$a" = ERASE ] || { echo aborted; exit 1; }

	echo "== rootfs image: $IMG ($(stat -c%s "$IMG") bytes) =="
	adb shell "umount $target_dev 2>/dev/null; umount /external_sd 2>/dev/null; true" </dev/null
	echo "== streaming image to $target_dev (several minutes over USB) =="
	adb shell "dd of=$target_dev bs=64k" < "$IMG"
	adb shell sync
	echo "== NOT running TWRP's on-device e2fsck/resize2fs -- see the header above."
	echo "== done. Flash the boot bundle with scripts/flash-boot-set.sh, then reboot to system. =="
	;;

userdata)
	: "${IMG:?pass IMG=<path to a raw ext4 .img, labelled $label> -- see the header above for how to build one per distro}"
	[ -f "$IMG" ] || { echo "$IMG not found" >&2; exit 1; }
	cat >&2 <<'EOF'
=========================  DESTRUCTIVE  =========================
 This writes the rootfs image directly over
 /dev/block/by-name/userdata and ERASES STOCK ANDROID /data
 (accounts, apps, internal storage). There is no undo.

 Rollback: restore a TWRP nandroid backup of `userdata`, or
 reflash stock firmware with Odin.

 Requirements: tablet in TWRP, `adb devices` shows it in
 `recovery` mode, and you have a fresh `userdata` backup pulled
 to this PC.
===============================================================
EOF
	if ! adb get-state </dev/null 2>/dev/null | grep -q recovery; then
		echo "device is not in recovery (TWRP) mode -- aborting" >&2
		exit 1
	fi
	read -rp "Type ERASE-USERDATA to proceed: " a
	[ "$a" = ERASE-USERDATA ] || { echo aborted; exit 1; }

	echo "== rootfs image: $IMG ($(stat -c%s "$IMG") bytes) =="
	adb shell 'umount /data 2>/dev/null; umount /dev/block/by-name/userdata 2>/dev/null; true' </dev/null
	echo "== streaming image to /dev/block/by-name/userdata (this takes a while) =="
	adb shell 'dd of=/dev/block/by-name/userdata bs=64k' < "$IMG"
	adb shell sync
	echo "== NOT running TWRP's on-device e2fsck/resize2fs -- see the header above."
	echo "== done. Flash the boot bundle with scripts/flash-boot-set.sh, then reboot to system. =="
	;;

*)
	usage
	;;
esac
