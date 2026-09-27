#!/usr/bin/env bash
# Run inside nix develop. Creates a fresh, isolated install from the saved tar.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
stage="$repo/out/internal-fedora"
[ ! -e "$stage" ] || { echo "Refusing existing staging directory: $stage" >&2; exit 1; }
mkdir -p "$stage/rootfs"
uid=$(id -u); gid=$(id -g)
subuid=$(awk -F: -v u="$(id -un)" '$1==u{print $2;exit}' /etc/subuid)
subgid=$(awk -F: -v u="$(id -gn)" '$1==u{print $2;exit}' /etc/subgid)
: "${subuid:=100000}" "${subgid:=100000}"
ns() {
    unshare --user --map-users "0:$uid:1" --map-users "1:$subuid:65536" \
        --map-groups "0:$gid:1" --map-groups "1:$subgid:65536" --mount --fork -- "$@"
}
ns tar --numeric-owner --xattrs --acls -xzf "$repo/out/fedora/x716b-fedora-44-gnome-rootfs.tar.gz" -C "$stage/rootfs"
ns cp -a "$repo/out/kernel/modules-out/lib/modules/." "$stage/rootfs/usr/lib/modules/"
ns cp -a "$repo/rootfs/overlay-internal/." "$stage/rootfs/"
ns chmod 755 "$stage/rootfs/usr/libexec/gts9wifi-grow-rootfs"
ns chmod 755 "$stage/rootfs/usr/libexec/gts9wifi-sensor-registry-perms"
ns sed -i 's/LABEL=X716B_ROOT/LABEL=X716B_INTERNAL/g' "$stage/rootfs/etc/fstab"
# A reused image's stamp must not suppress filesystem growth on userdata.
ns rm -f "$stage/rootfs/var/lib/gts9wifi-rootfs-grown"
ns depmod -b "$stage/rootfs" "$(cat "$repo/out/kernel/include/config/kernel.release")"
bash "$repo/scripts/build-rootfs-image.sh" "$stage/rootfs" "$stage/rootfs.img"
tune2fs -L X716B_INTERNAL "$stage/rootfs.img"
e2fsck -fn "$stage/rootfs.img"
BUILD_OUT="$stage" REAL_ROOT_LABEL=X716B_INTERNAL REAL_ROOT_LABEL_ONLY=1 \
    bash "$repo/scripts/build-real-root-initramfs.sh"
sha256sum "$stage/rootfs.img" "$stage/real-root-initramfs.cpio.gz"
