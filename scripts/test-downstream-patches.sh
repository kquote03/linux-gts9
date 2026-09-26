#!/usr/bin/env bash
# Reproducibility check for every downstream-patched component: fetch each
# pinned source (specs/sources.lock), verify the checkout, apply its patch
# series in order, and fail if anything does not apply cleanly. Also fails if
# a patch file under specs/*/patches/ is not listed in any series (an orphan
# would silently never be applied by any distro builder).
#
# Needs network, git and GNU patch only -- no build dependencies. Suitable for
# CI. Kernel patches are checked by scripts/build-mainline-kernel.sh (they are
# applied to the pinned kernel checkout with marker checks there).
#
# Usage: scripts/test-downstream-patches.sh [COMPONENT...]   (default: all)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/downstream.sh
. "$here/lib/downstream.sh"
ds_load_lock

all=(LIBSSC PD_MAPPER HEXAGONRPCD IIO_SENSOR_PROXY LIBCAMERA V4L2_RELAYD V4L2LOOPBACK)
if [ $# -gt 0 ]; then
	sel=()
	for c in "$@"; do sel+=("$(printf '%s' "$c" | tr 'a-z-' 'A-Z_')"); done
else
	sel=("${all[@]}")
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail=0

for name in "${sel[@]}"; do
	if ( ds_prepare "$name" "$work/$name" ); then
		echo "   OK   $name"
	else
		echo "   FAIL $name" >&2
		fail=1
	fi
done

echo "== every patch file is listed in a series =="
for dir in "$DS_SPECS"/*/; do
	[ -d "$dir/patches" ] || continue
	base=$(basename "$dir")
	if [ ! -f "$dir/series" ]; then
		# Directories deliberately not applied (see their README) carry no series.
		if [ -f "$dir/README.md" ] && grep -q 'not applied\|historical' "$dir/README.md"; then
			echo "   skip $base (documented as not applied)"
			continue
		fi
		echo "   FAIL $base has patches but no series file" >&2
		fail=1
		continue
	fi
	for p in "$dir"/patches/*.patch; do
		if ! ds_series_files "$dir" | grep -qx "$p"; then
			echo "   FAIL $base/patches/$(basename "$p") is not in $base/series" >&2
			fail=1
		fi
	done
done

if [ "$fail" = 0 ]; then
	echo "== all downstream patch series apply cleanly to their pinned sources =="
else
	echo "== FAILED ==" >&2
	exit 1
fi
