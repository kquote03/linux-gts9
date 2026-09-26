#!/usr/bin/env bash
# Shared, distro-agnostic helpers for fetching pinned upstream sources and
# applying this project's downstream patch series to them. Sourced (not run)
# by scripts/build-downstream-userland.sh, scripts/build-mainline-kernel.sh
# and scripts/test-downstream-patches.sh; needs only bash, git and GNU patch.
#
# Layout it relies on (relative to the repository root, i.e. two directories
# above this file -- so the whole tree can be copied anywhere, e.g. into a
# build chroot, and still work):
#   specs/sources.lock            pins: <NAME>_URL / _COMMIT / _SERIES
#   specs/<series-dir>/series     ordered patch list, one file name per line
#   specs/<series-dir>/patches/   the patch files
#
# See docs/downstream-patches.md.

DS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DS_SPECS=$DS_ROOT/specs

ds_die() { echo "downstream: $*" >&2; exit 1; }

# Load the pins. Idempotent.
ds_load_lock() {
	[ -f "$DS_SPECS/sources.lock" ] || ds_die "missing $DS_SPECS/sources.lock"
	# shellcheck disable=SC1091
	. "$DS_SPECS/sources.lock"
}

# ds_var NAME FIELD -> value of NAME_FIELD from the lock (empty if unset).
ds_var() {
	local v="${1}_${2}"
	printf '%s' "${!v-}"
}

# ds_fetch NAME DEST
# Check out the pinned commit of component NAME (as spelled in sources.lock,
# e.g. LIBCAMERA) into the empty/new directory DEST and verify HEAD.
# A shallow fetch of the exact commit is tried first (GitHub, GitLab and
# Forgejo allow it); hosts that do not fall back to a full clone.
ds_fetch() {
	local name=$1 dest=$2 url commit head attempt
	url=$(ds_var "$name" URL)
	commit=$(ds_var "$name" COMMIT)
	[ -n "$url" ] && [ -n "$commit" ] || ds_die "no URL/COMMIT for $name in sources.lock"
	[[ $commit =~ ^[0-9a-f]{40}$ ]] || ds_die "$name: COMMIT must be a full 40-hex id, got '$commit'"

	rm -rf -- "$dest"
	mkdir -p "$dest"
	git -C "$dest" init -q
	git -C "$dest" remote add origin "$url"
	for attempt in 1 2 3; do
		if git -C "$dest" fetch -q --depth 1 origin "$commit" 2>/dev/null; then
			break
		fi
		if git -C "$dest" fetch -q origin 2>/dev/null; then
			break
		fi
		[ "$attempt" != 3 ] || ds_die "$name: cannot fetch $url"
		sleep 5
	done
	git -C "$dest" checkout -q --detach "$commit" \
		|| ds_die "$name: commit $commit not found at $url"
	head=$(git -C "$dest" rev-parse HEAD)
	[ "$head" = "$commit" ] || ds_die "$name: checkout is at $head, expected the pinned $commit"
}

# ds_series_dir NAME -> absolute path of the component's specs directory
# ("" if the component carries no patches).
ds_series_dir() {
	local s
	s=$(ds_var "$1" SERIES)
	[ -n "$s" ] && printf '%s' "$DS_SPECS/$s"
	return 0
}

# ds_series_files DIR -> the patch paths listed in DIR/series, in order.
ds_series_files() {
	local dir=$1 line
	[ -f "$dir/series" ] || ds_die "missing $dir/series"
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%#*}
		line=${line//[[:space:]]/}
		[ -n "$line" ] || continue
		[ -f "$dir/patches/$line" ] || ds_die "$dir/series lists $line but $dir/patches/$line does not exist"
		printf '%s\n' "$dir/patches/$line"
	done <"$dir/series"
}

# ds_apply_series SRCDIR PATCHDIR
# Apply PATCHDIR/series to SRCDIR in order with GNU patch (-p1). Every patch
# is dry-run first so a failure names the offending patch and leaves the tree
# untouched by it. Works on git checkouts and plain source trees alike.
ds_apply_series() {
	local src=$1 dir=$2 p files
	# No process substitution anywhere in this file: build chroots often lack
	# /dev/fd, where `< <(cmd)` fails with "/dev/fd/NN: No such file".
	files=$(ds_series_files "$dir")
	while IFS= read -r p; do
		patch -d "$src" -p1 --forward --batch --no-backup-if-mismatch --dry-run <"$p" >/dev/null \
			|| ds_die "patch does not apply: $(basename "$p") (series in $dir)"
		patch -d "$src" -p1 --forward --batch --no-backup-if-mismatch <"$p" >/dev/null
		echo "   applied $(basename "$p")"
	done <<<"$files"
}

# ds_prepare NAME DEST -> fetch the pinned source and apply its series (if any).
ds_prepare() {
	local name=$1 dest=$2 dir
	echo "== $name: fetching $(ds_var "$name" URL) @ $(ds_var "$name" COMMIT | cut -c1-12) =="
	ds_fetch "$name" "$dest"
	dir=$(ds_series_dir "$name")
	if [ -n "$dir" ]; then
		ds_apply_series "$dest" "$dir"
	fi
}

# ds_series_digest DIR -> sha256 over the ordered patch contents (provenance).
ds_series_digest() {
	local dir=$1
	if [ -f "$dir/series" ]; then
		ds_series_files "$dir" | xargs cat | sha256sum | cut -d' ' -f1
	else
		echo none
	fi
}
