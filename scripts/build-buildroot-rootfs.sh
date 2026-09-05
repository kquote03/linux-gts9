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

# nixpkgs' compiler wrapper enables a "format" hardening flag by default
# (NIX_HARDENING_ENABLE, part of its standard security-hardening flag set)
# that turns on -Werror=format-security. GCC's own libcpp source (built as
# Buildroot's internal host-gcc-initial, a throwaway build-time host tool,
# not a shipped artifact) has several non-literal-format-string calls
# (e.g. libcpp/expr.cc's cpp_warning_with_line(..., 0, message)) that are
# tolerated by upstream GCC's own bootstrap toolchain but become hard
# errors under this specific hardening flag -- confirmed by reproducing
# the exact failure ("format not a string literal and no format
# arguments [-Werror=format-security]") and testing that dropping just
# this one flag fixes it. Scoped to this script's own environment, not
# shell.nix globally: the rest of this project's builds have no reason to
# need "format" hardening disabled, and Buildroot's own internal host
# tools were never going to benefit from Nix's runtime hardening anyway.
export NIX_HARDENING_ENABLE="${NIX_HARDENING_ENABLE//format/}"

# shell.nix's llvm.bintools (needed on PATH for Kbuild's own LLVM=1
# ld.lld/etc. discovery -- see that file) ships llvm-windres aliased as a
# plain `windres`, a real, working binary but for an entirely irrelevant
# target (Windows resource compilation). freetype's own libtool-generated
# build detects any `windres` on PATH at its own configure time and
# unconditionally tries to compile a Windows .rc resource file as part of
# an otherwise normal Linux/musl target build, failing with "'windows.h'
# file not found" (confirmed: this exact failure, `ftver.rc`, nothing to
# do with our actual target). RC must be truly EMPTY, not merely a no-op
# stub -- first tried RC=: (a shell no-op), which made freetype's own
# builds/freetype.mk `ifneq ($(RC),)` conditional (which gates whether
# ftver.rc/ftver.o is added to the link at all -- read directly, not
# guessed) see RC as non-empty and still add ftver.o to the link, except
# now nothing actually produced that file (":" ran and did nothing),
# failing later at the link step instead ("cannot find .../ftver.o").
# An empty RC correctly makes that conditional false and skips ftver
# entirely, without needing to strip llvm-binutils-wrapper's directory
# from PATH (ar/ld/nm/objcopy/ranlib from that same directory are
# legitimately relied on elsewhere in this build, confirmed in
# HOSTAR/HOSTLD/etc. above).
export RC=

if [ ! -d "$brdir/.git" ]; then
	echo "Buildroot source not found at $brdir -- run scripts/fetch-buildroot.sh first" >&2
	exit 1
fi

# host-patchelf (a real Buildroot-internal host tool, needed by its own
# "host-finalize" step to fix up RPATHs on everything else it just built)
# links against libstdc++.so.6 with no rpath at all, and fails at runtime
# with "error while loading shared libraries: libstdc++.so.6: cannot open
# shared object file" -- even inside nix-shell, since Nix deliberately
# doesn't expose a global LD_LIBRARY_PATH/ld.so.cache the way a normal FHS
# distro would (confirmed: `ldd` on the built binary shows libgcc_s.so.1
# resolving via some other, already-registered mechanism, but not
# libstdc++.so.6). Root cause: Buildroot resolves HOSTLD to the raw
# llvm-binutils `ld` directly (Makefile:311-332, same mechanism behind the
# earlier HOSTCPP fix) rather than linking through the properly-wrapped
# `c++`, which is what would normally auto-inject a working rpath on
# NixOS -- a real, generalizable gap for any C++ host tool that links via
# $(HOSTLD) instead of $(HOSTCXX), not unique to patchelf.
#
# Fix: copy the exact libstdc++.so.6 our wrapped c++ actually uses into
# Buildroot's own host/lib/ -- already on every host tool's rpath (its own
# per-package LDFLAGS explicitly add `-Wl,-rpath,$(HOST_DIR)/lib`,
# confirmed by reading an earlier package's actual configure invocation),
# so this needs no further build-system changes once the file is there.
mkdir -p "$outdir/host/lib"
libstdcxx="$(c++ -print-file-name=libstdc++.so.6)"
if [ "$libstdcxx" = "libstdc++.so.6" ]; then
	echo "could not resolve libstdc++.so.6 via 'c++ -print-file-name' -- run this inside nix-shell" >&2
	exit 1
fi
cp -Lfv "$libstdcxx" "$outdir/host/lib/libstdc++.so.6"

echo "== installing board defconfig into the Buildroot tree =="
install -m 0644 "$repo_root/buildroot/configs/x716_defconfig" \
	"$brdir/configs/x716_defconfig"

# Buildroot's own host-dependency check (support/dependencies/dependencies.sh)
# hardcodes a literal `/usr/bin/file` path check ("'file' must be ... exactly
# /usr/bin/file, otherwise libtool fails in incomprehensible ways" -- a
# decades-old FHS assumption). NixOS has no /usr/bin/file (confirmed: `file`
# is on PATH via /run/current-system/sw/bin/file, a real, working install --
# just not at that literal path -- and writing to /usr/bin isn't ours to do,
# it's root-owned outside this repo's scope). Patched to check via PATH
# instead, applied idempotently to the fetched (gitignored) checkout so it
# survives a fresh scripts/fetch-buildroot.sh. This exact hardcoded-path
# check is a common complaint on any non-FHS Linux setup (containers without
# /usr/bin, NixOS, etc.), not something specific to this project.
dep_check="$brdir/support/dependencies/dependencies.sh"
if grep -q 'check_prog_host "/usr/bin/file"' "$dep_check"; then
	sed -i 's#check_prog_host "/usr/bin/file"#check_prog_host "file"#' "$dep_check"
fi

mkdir -p "$outdir"

# Buildroot's top-level Makefile resolves HOSTCPP via `which cpp` itself
# (Makefile:311-332), unconditionally re-running that `which` even if
# HOSTCPP is already set to a bare name -- so exporting CPP in shell.nix
# doesn't help here (that only covers tools that consult $CPP directly).
# On this machine plain `cpp` on PATH resolves to llvm.clang-unwrapped's
# bare cpp (needed on PATH for Kbuild's own LLVM=1 discovery), which has
# no default header search paths on NixOS and fails every host package's
# autoconf preprocessor sanity check ("C preprocessor ... fails sanity
# check", first hit building host-attr). Point HOSTCPP at the properly-
# wrapped gcc toolchain's own cpp by its full path instead of a bare name,
# since `which` can't resolve a "cc -E"-style override (not a single
# executable) and PATH order alone can't be relied on to prefer it.
hostcpp="$(dirname "$(command -v cc)")/cpp"
if [ ! -x "$hostcpp" ]; then
	echo "expected a working cpp next to cc at $hostcpp -- not found" >&2
	exit 1
fi

echo "== defconfig =="
make -C "$brdir" O="$outdir" HOSTCPP="$hostcpp" x716_defconfig

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
make -C "$brdir" O="$outdir" HOSTCPP="$hostcpp" BR2_ROOTFS_OVERLAY="$overlay_dir" \
	-j"${BUILD_JOBS:-$(nproc)}"

image=$outdir/images/rootfs.cpio.gz

echo
echo "== build artifacts =="
ls -la "$image"
echo "rootfs.cpio.gz sha256: $(sha256sum "$image" | cut -d' ' -f1)"
