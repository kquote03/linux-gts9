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
set -euo pipefail

rootdir=${1:?usage: $0 <rootfs-dir> <out.img> [margin-MiB]}
outimg=${2:?usage: $0 <rootfs-dir> <out.img> [margin-MiB]}
margin_mib=${3:-1024}

[ -d "$rootdir" ] || { echo "$rootdir is not a directory" >&2; exit 1; }
command -v mke2fs >/dev/null || { echo "mke2fs not found -- run inside 'nix develop'" >&2; exit 1; }

size_kib=$(du -sk --apparent-size "$rootdir" | cut -f1)
size_mib=$(( (size_kib + 1023) / 1024 + margin_mib ))

echo "== rootfs: $rootdir (~$((size_kib / 1024)) MiB) + ${margin_mib} MiB margin =="
echo "== building $outimg (${size_mib} MiB, ext4, label X716B_ROOT) =="
rm -f "$outimg"
mke2fs -q -t ext4 -L X716B_ROOT -d "$rootdir" "$outimg" "${size_mib}M"

ls -la "$outimg"
echo "sha256: $(sha256sum "$outimg" | cut -d' ' -f1)"
echo "done -- deploy with: scripts/deploy-rootfs.sh --i-understand-this-writes-to-the-device twrp-sd IMG=$outimg"
