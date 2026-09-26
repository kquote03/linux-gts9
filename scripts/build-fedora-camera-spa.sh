#!/bin/bash
# Run inside the Fedora rootfs after installing the source-built libcamera.
set -euo pipefail
spec_dir=${1:?usage: build-fedora-camera-spa.sh STAGED_PIPEWIRE_SPEC_DIR}
install_root=${DESTDIR:-}
version=$(rpm -q --qf '%{VERSION}' pipewire-libs)
binary_nevra=$(rpm -q pipewire-libs)
source_rpm=$(rpm -q --qf '%{SOURCERPM}' pipewire-libs)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Unsupported PipeWire release: $version" >&2; exit 1;
}
[[ $(pkg-config --modversion libpipewire-0.3) == "$version" ]] || {
    echo 'Installed PipeWire development headers do not match its core library' >&2; exit 1;
}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
# Prepare the exact Fedora source package, including downstream patches.
# Refuse a newer mirror version rather than rebuilding an incompatible SPA.
mkdir -p "$work_dir/rpm"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
for attempt in 1 2 3; do
    dnf download --source --destdir="$work_dir" "$binary_nevra" && break
    [[ $attempt != 3 ]] || exit 1
    sleep 5
done
[[ -f "$work_dir/$source_rpm" ]] || {
    echo "Exact installed source package unavailable: $source_rpm" >&2; exit 1;
}
rpm -i --nodeps --define "_topdir $work_dir/rpm" "$work_dir/$source_rpm"
rpmbuild -bp --nodeps --define "_topdir $work_dir/rpm" "$work_dir/rpm/SPECS/pipewire.spec"
# No process substitution: the build chroot has no /dev/fd, so `< <(find ...)`
# fails with "/dev/fd/63: No such file or directory".
found_dirs=$(find "$work_dir/rpm/BUILD" -type f \
    -path '*/spa/plugins/libcamera/libcamera-source.cpp' -printf '%h\n')
source_dirs=()
while IFS= read -r line; do
    [[ -z $line ]] || source_dirs+=("$line")
done <<<"$found_dirs"
[[ ${#source_dirs[@]} == 1 ]] || {
    echo 'Expected exactly one prepared PipeWire source tree' >&2; exit 1;
}
source_dir=${source_dirs[0]%/spa/plugins/libcamera}
python3 "$spec_dir/test-control-pagination.py" "$source_dir"
# Release build: meson defaults to buildtype=debug (-O0); the rest of the
# camera stack was found to be built that way (docs/porting-log.md Session 24).
meson setup "$work_dir/build" "$source_dir" --prefix=/usr --libdir=lib64 --buildtype=release \
    -Dauto_features=disabled -Dspa-plugins=enabled -Ddbus=disabled \
    -Dudev=enabled -Dlibcamera=enabled -Dsession-managers=[]
meson compile -C "$work_dir/build" spa-libcamera
# Hardware idle memory validation is still required before activation.
install -Dm755 "$work_dir/build/spa/plugins/libcamera/libspa-libcamera.so" \
    "$install_root/usr/lib64/spa-0.2/libcamera/libspa-libcamera.so.disabled"
rm -f "$install_root/usr/lib64/spa-0.2/libcamera/libspa-libcamera.so"
mkdir -p "$install_root/usr/share/gts9-camera"
{
    echo 'source_kind=Fedora-SRPM-prepared-with-downstream-patches'
    printf 'pipewire_package=%s\n' "$binary_nevra"
    printf 'pipewire_upstream_version=%s\n' "$version"
    printf 'pipewire_source_rpm=%s\n' "$source_rpm"
    printf 'pipewire_source_sha256=%s\n' "$(sha256sum "$work_dir/$source_rpm" | cut -d' ' -f1)"
    printf 'libcamera_version=%s\n' "$(pkg-config --modversion libcamera)"
    echo 'plugin_default=disabled-pending-hardware-validation'
} > "$install_root/usr/share/gts9-camera/spa-build.txt"
