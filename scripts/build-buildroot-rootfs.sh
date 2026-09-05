#!/usr/bin/env bash
# Build the minimal Weston + weston-terminal rootfs (Session 5, 2026-09-05).
# This is a SEPARATE, smaller "prove the display works" rootfs -- not the
# debootstrap-based Phase 4 Ubuntu rootfs (see docs/hardware-facts.md).
# Assumes scripts/fetch-buildroot.sh has already pinned the checkout.
#
# Ships as an initramfs (BR2_TARGET_ROOTFS_CPIO), like the debug bring-up
# ramdisk -- nothing in this port's boot chain does a switch_root today, so
# that's the natural fit, not a detour. Plug the result into
# scripts/build-android-v4-bundle.sh via its existing BRINGUP_RAMDISK
# override:
#
#   BRINGUP_RAMDISK=out/buildroot/images/rootfs.cpio.gz \
#       bash scripts/build-android-v4-bundle.sh
#
# Must run inside `nix-shell` (shell.nix) for a host gcc (Buildroot's own
# Kconfig tooling needs one) and wget (Buildroot's own package downloader).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
brdir=${BUILDROOT_SRC:-$repo_root/buildroot/upstream}
outdir=${BUILD_OUT:-$repo_root/out/buildroot}
overlay_dir=$repo_root/buildroot/rootfs-overlay

if [ ! -d "$brdir/.git" ]; then
	echo "Buildroot source not found at $brdir -- run scripts/fetch-buildroot.sh first" >&2
	exit 1
fi

echo "== installing board defconfig into the Buildroot tree =="
install -m 0644 "$repo_root/buildroot/configs/x716_defconfig" \
	"$brdir/configs/x716_defconfig"

mkdir -p "$outdir"

echo "== defconfig =="
make -C "$brdir" O="$outdir" x716_defconfig

echo "== verifying no defconfig-requested symbol was silently dropped =="
# Same discipline as scripts/build-mainline-kernel.sh's fragment check --
# a Kconfig symbol whose `depends on` isn't met is silently omitted
# entirely (no warning), not flagged as an error, so this has to be
# checked explicitly rather than trusted.
fail=0
while IFS='=' read -r key val; do
	[ -z "$key" ] && continue
	case "$key" in \#*) continue ;; esac
	actual=$(grep -m1 "^$key=" "$outdir/.config" || true)
	if [ "$actual" != "$key=$val" ]; then
		echo "MISMATCH: $key wanted $val, .config has: ${actual:-<unset>}" >&2
		fail=1
	fi
done < <(grep -E '^BR2_[A-Z0-9_]+=' "$repo_root/buildroot/configs/x716_defconfig")
if [ "$fail" -ne 0 ]; then
	echo "one or more defconfig symbols were dropped/changed by dependency resolution -- see above" >&2
	exit 1
fi
echo "all defconfig symbols present as requested"

echo "== building (this fetches and builds Buildroot's own toolchain + every package -- long) =="
# BR2_ROOTFS_OVERLAY is passed as a make command-line override rather than
# baked into the committed defconfig: GNU Make command-line assignments
# take precedence over the plain NAME=value lines Kconfig's .config is
# made of, so this stays reproducible on a fresh machine regardless of
# repo_root's absolute path (confirmed: Makefile:809-816 just consumes
# $(BR2_ROOTFS_OVERLAY) as an ordinary Make variable, no `override` keyword
# involved that would block a command-line assignment from winning).
make -C "$brdir" O="$outdir" BR2_ROOTFS_OVERLAY="$overlay_dir" \
	-j"${BUILD_JOBS:-$(nproc)}"

image=$outdir/images/rootfs.cpio.gz

echo
echo "== build artifacts =="
ls -la "$image"
echo "rootfs.cpio.gz sha256: $(sha256sum "$image" | cut -d' ' -f1)"
