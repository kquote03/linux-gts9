#!/usr/bin/env bash
# Pack a plain rootfs directory (Fedora's or Debian's build output --
# NixOS builds its own raw image directly via nixos/packages/
# rootfs-image.nix) into a raw ext4 image labelled X716B_ROOT, for
# scripts/deploy-rootfs.sh's twrp-sd/userdata targets.
#
# Unprivileged, no mount/loop device and no root needed: `mke2fs -d`
# (e2fsprogs >= 1.43, confirmed 1.47.4 here via `nix develop`) populates
# the new filesystem directly from a source directory, preserving
# ownership/permissions as recorded by stat() without ever chown()'ing
# anything on the real host filesystem.
#
# Usage: scripts/build-rootfs-image.sh <rootfs-dir> <out.img> [margin-MiB]
#
# margin-MiB (default 1024): free space left inside the image beyond the
# rootfs directory's own size, for kernel modules/logs/etc. written on
# first boot before gts9wifi-grow-rootfs.service (or NixOS's
# fileSystems."/".autoResize) grows the filesystem to fill its real
# partition.
#
# Runs mke2fs itself inside the same wide subuid/subgid-mapped user
# namespace build-debian-rootfs.sh's run_in_ns uses -- confirmed live,
# a plain unprivileged mke2fs -d aborts outright ("Permission denied
# while changing working directory to dissect-root", not just skipping
# that one entry) on any rootfs directory containing content created via
# that mapped namespace (e.g. systemd's own /run/systemd/dissect-root,
# sddm's /var/lib/sddm -- real root-owned/non-host-uid paths mke2fs
# needs read+traverse access to, which this script's own plain host user
# does not have without the same mapping that created them).
set -euo pipefail

rootdir=${1:?usage: $0 <rootfs-dir> <out.img> [margin-MiB]}
outimg=${2:?usage: $0 <rootfs-dir> <out.img> [margin-MiB]}
margin_mib=${3:-1024}

[ -d "$rootdir" ] || { echo "$rootdir is not a directory" >&2; exit 1; }
command -v mke2fs >/dev/null || { echo "mke2fs not found -- run inside 'nix develop'" >&2; exit 1; }

myuid=$(id -u)
mygid=$(id -g)
subuid_base=$(awk -F: -v u="$(id -un)" '$1==u{print $2}' /etc/subuid | head -1)
subgid_base=$(awk -F: -v g="$(id -gn)" '$1==g{print $2}' /etc/subgid | head -1)
: "${subuid_base:=100000}" "${subgid_base:=100000}"
run_in_ns() {
	unshare --user \
		--map-users "0:$myuid:1" --map-users "1:$subuid_base:65536" \
		--map-groups "0:$mygid:1" --map-groups "1:$subgid_base:65536" \
		--mount --fork -- "$@"
}

# || true: du exits nonzero (aborting the script right here under set -e,
# with no error message) if it can't read every subdirectory -- confirmed
# live, content created via a mapped user namespace (e.g. systemd's own
# /run/systemd/dissect-root, sddm's /var/lib/sddm) ends up unreadable to
# this script's own plain unprivileged invocation. The size total is
# still accurate for everything readable, which is everything that
# actually lands in the image via mke2fs -d below.
size_kib=$( (du -sk --apparent-size "$rootdir" || true) | cut -f1)
size_mib=$(( (size_kib + 1023) / 1024 + margin_mib ))

echo "== rootfs: $rootdir (~$((size_kib / 1024)) MiB) + ${margin_mib} MiB margin =="
echo "== building $outimg (${size_mib} MiB, ext4, label X716B_ROOT) =="
rm -f "$outimg"
run_in_ns mke2fs -q -t ext4 -L X716B_ROOT -d "$rootdir" "$outimg" "${size_mib}M"

ls -la "$outimg"
echo "sha256: $(sha256sum "$outimg" | cut -d' ' -f1)"
echo "done -- deploy with: scripts/deploy-rootfs.sh --i-understand-this-writes-to-the-device twrp-sd IMG=$outimg"
