#!/usr/bin/env bash
# Build this project's downstream-patched userland components from pinned
# sources, the same way on any distro. Run it on the target itself (or inside
# its build chroot) as root after installing the distro's build dependencies;
# the rootfs builders (scripts/build-fedora-rootfs.sh, build-debian-rootfs.sh)
# do exactly that, and a new distro port only needs to do the same -- see
# docs/downstream-patches.md for the per-component dependency lists.
#
# Sources and patch order come from specs/sources.lock and
# specs/<component>/series (scripts/lib/downstream.sh); nothing about a
# component's version, patches or build flags lives in a distro builder.
#
# Usage:
#   build-downstream-userland.sh [options] COMPONENT...
#
# Components: libssc pd-mapper hexagonrpcd iio-sensor-proxy libcamera
#             v4l2-relayd            (or: all)
#
# Options:
#   --prefix DIR    install prefix                          (default /usr)
#   --libdir DIR    library dir relative to the prefix, e.g. lib64 or
#                   lib/aarch64-linux-gnu; default: the build system's own
#                   default for the distro (meson/autotools)
#   --destdir DIR   stage into DIR instead of installing into the live system
#   --workdir DIR   scratch directory (default: a fresh mktemp -d)
#   --keep          keep the scratch directory
#   --jobs N        parallel jobs (default: nproc)
#
# The SPA (PipeWire) libcamera plugin is not built here: it must match the
# distro's own PipeWire package, so it stays with the distro builder
# (Fedora: scripts/build-fedora-camera-spa.sh).
set -euo pipefail

# git (init/fetch) wants a home for its config; build chroots often have none set.
export HOME=${HOME:-/root}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/downstream.sh
. "$here/lib/downstream.sh"
ds_load_lock

prefix=/usr
libdir=
destdir=
workdir=
keep=0
jobs=$(nproc 2>/dev/null || echo 2)
components=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case $1 in
	--prefix) prefix=${2:?}; shift 2 ;;
	--libdir) libdir=${2:?}; shift 2 ;;
	--destdir) destdir=${2:?}; shift 2 ;;
	--workdir) workdir=${2:?}; shift 2 ;;
	--keep) keep=1; shift ;;
	--jobs) jobs=${2:?}; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	all) components+=(libssc pd-mapper hexagonrpcd iio-sensor-proxy libcamera v4l2-relayd); shift ;;
	-*) ds_die "unknown option $1" ;;
	*) components+=("$1"); shift ;;
	esac
done
[ ${#components[@]} -gt 0 ] || { usage >&2; exit 2; }

if [ -z "$workdir" ]; then
	workdir=$(mktemp -d)
	[ "$keep" = 1 ] || trap 'rm -rf -- "$workdir"' EXIT
else
	mkdir -p "$workdir"
fi
D=${destdir}

need() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || ds_die "required tool '$c' not found (install the distro build dependencies, see docs/downstream-patches.md)"
	done
}
need git patch

libdir_meson=()
[ -z "$libdir" ] || libdir_meson=(--libdir="$libdir")

# meson_build NAME SRC [extra meson setup args...]
meson_build() {
	local name=$1 src=$2
	shift 2
	need meson ninja
	meson setup "$workdir/$name-build" "$src" --prefix="$prefix" "${libdir_meson[@]}" "$@"
	meson compile -C "$workdir/$name-build"
	DESTDIR="$D" meson install --no-rebuild -C "$workdir/$name-build"
}

# provenance NAME LOCKNAME [note]: record what was built, for reproducibility.
provenance() {
	local name=$1 lock=$2 dir out
	dir=$(ds_series_dir "$lock")
	out=$D$prefix/share/gts9-userland
	mkdir -p "$out"
	{
		echo "component=$name"
		echo "url=$(ds_var "$lock" URL)"
		echo "commit=$(ds_var "$lock" COMMIT)"
		echo "series_dir=${dir:+$(basename "$dir")}"
		echo "series_sha256=${dir:+$(ds_series_digest "$dir")}"
		[ -z "${3-}" ] || echo "build=$3"
	} >"$out/$name.txt"
}

build_libssc() {
	ds_prepare LIBSSC "$workdir/libssc-src"
	meson_build libssc "$workdir/libssc-src" -Db_lto=true
	provenance libssc LIBSSC
}

build_pd_mapper() {
	need make gcc
	ds_prepare PD_MAPPER "$workdir/pd-mapper-src"
	# Binary only (the sm8550 ADSP boots without service-registry JSONs); the
	# upstream Makefile ships its own systemd unit.
	make -C "$workdir/pd-mapper-src" prefix="$prefix"
	make -C "$workdir/pd-mapper-src" install prefix="$prefix" DESTDIR="$D"
	provenance pd-mapper PD_MAPPER
}

build_hexagonrpcd() {
	local src=$workdir/hexagonrpcd-src canon units u found
	ds_prepare HEXAGONRPCD "$src"
	meson_build hexagonrpcd "$src" -Db_lto=true
	install -Dm644 "$DS_SPECS/hexagonrpcd-samsung/patches/10-fastrpc.rules" \
		-t "$D$prefix/lib/udev/rules.d/"
	# systemd-services.patch installs the units below <libdir>/systemd/system,
	# which is lib64/ on Fedora and lib/<multiarch>/ on Debian -- neither is
	# on systemd's unit search path. Relocate them next to every other unit.
	canon=$D$prefix/lib/systemd/system
	found=$(find "$D$prefix" -maxdepth 4 -type d -path '*/systemd/system' 2>/dev/null || true)
	while IFS= read -r units; do
		[ -n "$units" ] && [ "$units" != "$canon" ] || continue
		mkdir -p "$canon"
		for u in "$units"/hexagonrpcd-*.service; do
			[ -e "$u" ] && mv "$u" "$canon/"
		done
		rmdir -p --ignore-fail-on-non-empty "$units" 2>/dev/null || true
	done <<<"$found"
	provenance hexagonrpcd HEXAGONRPCD
}

build_iio_sensor_proxy() {
	ds_prepare IIO_SENSOR_PROXY "$workdir/iio-sensor-proxy-src"
	# -Dssc-support=enabled links libssc (build libssc first).
	meson_build iio-sensor-proxy "$workdir/iio-sensor-proxy-src" -Dssc-support=enabled
	provenance iio-sensor-proxy IIO_SENSOR_PROXY
}

build_libcamera() {
	local src=$workdir/libcamera-src
	ds_prepare LIBCAMERA "$src"
	# --buildtype=release: meson defaults to `debug` (-O0), which made the
	# CPU software ISP several times slower (docs/porting-log.md Session 24).
	meson_build libcamera "$src" \
		--buildtype=release \
		-Dpipelines=simple \
		-Dipas=simple \
		-Dgstreamer=disabled \
		-Dcam=enabled \
		-Dcam-output-kms=disabled \
		-Dcam-output-sdl2=disabled \
		-Dqcam=disabled \
		-Ddocumentation=disabled \
		-Dtest=false \
		-Dlc-compliance=disabled \
		-Dpycamera=disabled \
		-Dv4l2=false \
		-Dtracing=disabled \
		-Dsoftisp-gpu=disabled
	install -Dm644 "$DS_SPECS/libcamera-x716b/tuning/hi1337-gts9.yaml" \
		"$D$prefix/share/libcamera/ipa/simple/hi1337-gts9.yaml"
	provenance libcamera LIBCAMERA "meson --buildtype=release"
}

build_v4l2_relayd() {
	local src=$workdir/v4l2-relayd-src
	need make autoconf automake libtoolize pkg-config
	ds_prepare V4L2_RELAYD "$src"
	(
		cd "$src"
		NOCONFIGURE=1 ./autogen.sh
		./configure --prefix="$prefix" ${libdir:+--libdir="$prefix/$libdir"}
		make -j"$jobs"
		make install DESTDIR="$D"
	)
	# Its own /etc/modprobe.d file re-declares v4l2loopback options
	# (card_label="Virtual Camera") and overrides the two labelled devices this
	# port configures in rootfs/overlay-common/usr/lib/modprobe.d/gts9-cameras.conf.
	rm -f "$D/etc/modprobe.d/v4l2-relayd.conf"
	provenance v4l2-relayd V4L2_RELAYD
}

for c in "${components[@]}"; do
	case $c in
	libssc) build_libssc ;;
	pd-mapper) build_pd_mapper ;;
	hexagonrpcd) build_hexagonrpcd ;;
	iio-sensor-proxy) build_iio_sensor_proxy ;;
	libcamera) build_libcamera ;;
	v4l2-relayd) build_v4l2_relayd ;;
	*) ds_die "unknown component '$c'" ;;
	esac
done
echo "== done: ${components[*]} (prefix $prefix${D:+, staged in $D}) =="
