#!/usr/bin/env bash
# Fetch the pinned Buildroot checkout used to build the minimal Weston
# rootfs (scripts/build-buildroot-rootfs.sh). This is a separate, smaller
# "prove the display works" rootfs, NOT the debootstrap-based Phase 4
# Ubuntu rootfs (see docs/hardware-facts.md) -- the two are unrelated and
# deliberately kept that way.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${BUILDROOT_SRC:-$repo_root/buildroot/upstream}
tag=${BUILDROOT_TAG:-2026.08}
# The pinned commit is the tag's dereferenced target commit, not the
# (annotated) tag object itself -- `git rev-parse HEAD` after a
# `--branch <tag>` clone lands on the commit, so that's what's verified
# below. Confirmed via: git ls-remote https://github.com/buildroot/buildroot.git
# refs/tags/2026.08 refs/tags/2026.08^{}
commit=${BUILDROOT_COMMIT:-d5180309b1b66ef3b8eaccca70ad69be8e0729a1}
upstream=https://github.com/buildroot/buildroot.git

mkdir -p "$(dirname "$target")"

if [ ! -d "$target/.git" ]; then
	echo "cloning $tag from upstream"
	git clone --depth 1 --branch "$tag" "$upstream" "$target"
else
	echo "already present: $target"
fi

head=$(git -C "$target" rev-parse HEAD)
if [ "$head" != "$commit" ]; then
	echo "checkout is at $head, expected the pinned $commit" >&2
	exit 1
fi

echo "pinned commit verified: $head"
git -C "$target" describe --always --tags

# Sanity check: this should actually be a Buildroot checkout, not just any
# repo that happened to be at this commit.
for f in Makefile "package/weston/Config.in" "package/weston-terminal/Config.in"; do
	path="$target/$f"
	if [ ! -f "$path" ]; then
		echo "expected Buildroot file missing: $path" >&2
		exit 1
	fi
done
echo "Buildroot layout looks right (weston/weston-terminal packages present)"
