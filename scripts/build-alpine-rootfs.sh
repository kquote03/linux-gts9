#!/usr/bin/env bash
# Predates the ADSP/audio/sensor work entirely (see docs/distro-porting.md
# for the device-overlay split that came after this script was last
# touched) -- if reviving this, apply rootfs/overlay-common/ and write an
# OpenRC equivalent of rootfs/overlay-systemd/, and pull firmware from
# vendor-firmware-dump/firmware/qcom-sm8550/ the same way
# build-fedora-rootfs.sh does. Likely otherwise stale against the current
# kernel config too -- not touched since.
#
# Build a real, persistent Alpine Linux (aarch64) root filesystem -- the
# Storage bring-up session's Phase D. This is the actual "Phase 4" distro
# rootfs, superseding the Buildroot Weston-only ramdisk (which stays as a
# separate, smaller "prove the display/touch work" artifact) and the
# debootstrap-based Ubuntu plan the docs previously named (see
# docs/porting-log.md's Storage bring-up entry for why Alpine, not Ubuntu).
#
# Two-stage bootstrap, no target-arch emulation needed for either stage:
#   1. Download + sha256-verify Alpine's official aarch64 "mini root
#      filesystem" tarball and extract it. This gives us a real base
#      system (busybox, apk-tools, OpenRC skeleton) *and* the release's
#      trusted apk signing keys (/etc/apk/keys/*.pub) for free -- these
#      are what stage 2 reuses, rather than separately sourcing keys.
#   2. Add packages beyond the bare base using the *host's own* apk-tools
#      (from nixpkgs, x86_64) pointed at `--root <dir> --arch aarch64`.
#      Modern apk-tools supports installing into a foreign-arch root
#      directly -- it fetches and unpacks matching aarch64 .apk files,
#      it doesn't need to *execute* target-arch code for that. `--no-scripts`
#      skips post-install trigger scripts (which _would_ need target-arch
#      execution); anything those scripts would have done that we actually
#      need (default users, service symlinks) is done by hand below,
#      since the package set here is small and well-understood.
#
# Must run inside `nix-shell` (shell.nix) for curl/sha256sum (coreutils)
# and mke2fs (e2fsprogs, already staged for the microSD partitioning this
# same session used). apk-tools itself is NOT in shell.nix (host-arch,
# only needed by this one script) -- run this via:
#   nix-shell --run 'nix-shell -p apk-tools --run "bash scripts/build-alpine-rootfs.sh"'
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out/alpine}
cachedir=${ALPINE_CACHE:-$repo_root/out/alpine-cache}
mkdir -p "$outdir" "$cachedir"

ALPINE_BRANCH=v3.20
ALPINE_VERSION=3.20.10
ALPINE_ARCH=aarch64
TARBALL="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
TARBALL_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${TARBALL}"
# From latest-releases.yaml at the time this script was written -- re-verify
# against https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/latest-releases.yaml
# if bumping ALPINE_VERSION.
TARBALL_SHA256="61ac877fdbcee6914731bc22a4ed5668ea3470f201f97a7078931c48b71bbeec"

REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main"
REPO_COMMUNITY="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community"

if ! command -v apk >/dev/null 2>&1; then
	echo "apk (host apk-tools) not found -- run this inside:" >&2
	echo "  nix-shell -p apk-tools --run 'bash scripts/build-alpine-rootfs.sh'" >&2
	echo "(from inside the project's own nix-shell, or standalone -- either way" >&2
	echo "apk-tools must be on PATH; it is deliberately not in shell.nix since" >&2
	echo "nothing else in this repo needs a host-arch apk binary)." >&2
	exit 1
fi

echo "== stage 1: minirootfs tarball =="
tarball_path="$cachedir/$TARBALL"
if [ ! -f "$tarball_path" ] || [ "$(sha256sum "$tarball_path" | cut -d' ' -f1)" != "$TARBALL_SHA256" ]; then
	echo "downloading $TARBALL_URL"
	curl -fL -o "$tarball_path.tmp" "$TARBALL_URL"
	got=$(sha256sum "$tarball_path.tmp" | cut -d' ' -f1)
	if [ "$got" != "$TARBALL_SHA256" ]; then
		echo "sha256 mismatch: got $got, expected $TARBALL_SHA256" >&2
		rm -f "$tarball_path.tmp"
		exit 1
	fi
	mv "$tarball_path.tmp" "$tarball_path"
else
	echo "using cached, checksum-verified $tarball_path"
fi

rootdir="$outdir/rootfs"
rm -rf "$rootdir"
mkdir -p "$rootdir"
tar -xzf "$tarball_path" -C "$rootdir"
echo "extracted to $rootdir"

echo "== stage 2: adding packages via host apk-tools (--root, no target-arch execution) =="
apk_keys="$rootdir/etc/apk/keys"
if [ ! -d "$apk_keys" ] || [ -z "$(ls -A "$apk_keys" 2>/dev/null)" ]; then
	echo "no trusted keys found in the extracted minirootfs ($apk_keys) -- aborting" >&2
	exit 1
fi

# openrc: real init (becomes PID 1 after switch_root, replacing this
#   port's ad-hoc bring-up-ramdisk /init).
# weston, weston-terminal, seatd: the exact stack already proven working
#   this session (Session 5/7) on the Buildroot rootfs -- same invocation,
#   now under OpenRC's service management instead of a hand-run command.
# openssh: carried over from the original "reachable over SSH" Phase 4 goal.
# util-linux (agetty): busybox's own getty is in the base already; agetty
#   is pulled in only if a later iteration needs its extra features
#   (kept minimal here -- busybox getty is used in the OpenRC service
#   below unless that proves insufficient on real hardware).
# mesa-dri-gallium: required live this session -- weston-backend-drm's own
#   declared dependency on so:libgbm.so.1 means weston's DRM backend tries
#   a real GBM/EGL renderer init (unlike the Buildroot rootfs, which has
#   zero Mesa installed at all and goes straight to weston's pixman
#   renderer), and without this package's actual DRI driver .so files on
#   disk that GBM init fails hard ("MESA-LOADER: failed to open msm/
#   kms_swrast/swrast", weston exiting instead of falling back) rather
#   than gracefully choosing pixman. This also happens to be the package
#   that would carry a real `msm_dri.so` if/when GPU (Adreno/freedreno)
#   acceleration is ever brought up -- not just a swrast/pixman fallback
#   enabler.
apk \
	--root "$rootdir" \
	--arch "$ALPINE_ARCH" \
	--keys-dir "$apk_keys" \
	-X "$REPO_MAIN" \
	-X "$REPO_COMMUNITY" \
	-U \
	--no-scripts \
	--usermode \
	--initdb \
	add openrc weston weston-backend-drm weston-terminal seatd openssh eudev mesa-dri-gallium

echo "== post-install: what --no-scripts skipped, done by hand =="
# alpine-baselayout's own post-install script normally prompts/sets a
# root password; skipped scripts leave root locked ("root:*::..." in
# /etc/shadow -- confirmed live this session: every password, including
# blank, is rejected with "Login incorrect" against a locked account, not
# actually a wrong-password case). An *empty* shadow field was tried next
# and also rejected ("Login incorrect" even on a blank password prompt) --
# whatever provides /bin/login here doesn't treat an empty hash as
# "passwordless", unlike the classic Unix convention this project's other
# ramdisks/rootfs rely on. Set a real hash instead: password is "alpine",
# purely a bring-up convenience (this device has no network exposure at
# this stage) -- revisit before this is ever a real, "leave it plugged
# in" daily-driver setup. Regenerate with: openssl passwd -6 -salt xyz alpine
ROOT_PASSWD_HASH='$6$xyz$F.6dSmj3bSZCH0SVVbVONJnmzLZIzLX2N5sOdr/qXHmhk48aPCfiWvdGW6Y0NXkGMZogkHPSzmnXiUa4t4BBS1'
sed -i "s|^root:\*:|root:${ROOT_PASSWD_HASH}:|" "$rootdir/etc/shadow"

# seatd's own post-install script normally creates a "seat" system group
# (seatd -g seat refuses to start without it -- confirmed live this
# session: "Could not find group by name 'seat'."). GID 990 is arbitrary
# but unused in the minirootfs's stock /etc/group (highest stock GID seen
# there is ping's 999) -- matches this project's existing convention of
# picking an unused ID rather than hardcoding one from a real system.
if ! grep -q '^seat:' "$rootdir/etc/group"; then
	echo "seat:x:990:" >> "$rootdir/etc/group"
fi

# A standard, non-root user (uid 1000, gid 100 "users" -- matching what
# busybox's own `adduser -D` produced when this was first done live this
# session), same "alpine" password/convenience caveat as root above.
# tty/audio/input/video group membership: sensible defaults for an
# interactive desktop-ish user on this board, not strictly required for
# anything yet.
if ! grep -q '^alpine:' "$rootdir/etc/passwd"; then
	USER_PASSWD_HASH=$(openssl passwd -6 -salt "$(head -c6 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')" alpine)
	echo "alpine:x:1000:100:Linux User,,,:/home/alpine:/bin/sh" >> "$rootdir/etc/passwd"
	echo "alpine:${USER_PASSWD_HASH}:20702:0:99999:7:::" >> "$rootdir/etc/shadow"
	mkdir -p "$rootdir/home/alpine"
	chown -R 1000:100 "$rootdir/home/alpine" 2>/dev/null || true
	for g in tty audio input video; do
		if grep -q "^${g}:" "$rootdir/etc/group"; then
			sed -i "s/^${g}:\([^:]*:[^:]*:\)\(.*\)$/${g}:\1\2,alpine/;s/:,alpine/:alpine/" "$rootdir/etc/group"
		fi
	done
fi

# openrc's own post-install script normally seeds default runlevels
# (sysinit/boot/default) with its stock service set and creates
# /run, /etc/os-release symlinks etc. Since we skipped scripts, wire up
# only what this board actually needs: the seatd/weston services below
# are added directly to the "default" runlevel via the same symlink
# mechanism OpenRC's own `rc-update add` would create.
#
# Deliberately NOT enabling udev/udev-trigger here even though eudev is
# installed: this project's own proven-working Weston setup (the
# Buildroot rootfs, and this same live session's manual chroot test) has
# never needed a running udev daemon -- plain devtmpfs already creates
# the /dev/dri and /dev/input nodes weston's DRM/libinput backends need.
# A whole udev subsystem is extra moving parts this iteration hasn't
# validated at all; skip it until there's a real reason to need it
# (hotplug, persistent device naming), rather than risk it stalling
# sysinit on a fresh, unverified path.
mkdir -p "$rootdir/etc/runlevels/"{sysinit,boot,default}
for svc in devfs dmesg modules sysctl hostname; do
	[ -e "$rootdir/etc/init.d/$svc" ] && \
		ln -sf "/etc/init.d/$svc" "$rootdir/etc/runlevels/sysinit/$svc" 2>/dev/null || true
done
for svc in seatd; do
	[ -e "$rootdir/etc/init.d/$svc" ] && \
		ln -sf "/etc/init.d/$svc" "$rootdir/etc/runlevels/default/$svc" 2>/dev/null || true
done

# Weston OpenRC service: same invocation already validated live on real
# hardware this session (backend=drm-backend.so, XDG_RUNTIME_DIR, the
# WAYLAND_DISPLAY-mismatch lesson from that same live session baked in as
# a comment for whoever next edits this).
cat > "$rootdir/etc/init.d/weston" <<'EOF'
#!/sbin/openrc-run
name="weston"
description="Weston Wayland compositor (DRM backend, pixman renderer)"

depend() {
	need seatd
	after sysinit
}

start() {
	ebegin "Starting weston"
	export XDG_RUNTIME_DIR=/run/user/0
	mkdir -p "$XDG_RUNTIME_DIR"
	chmod 0700 "$XDG_RUNTIME_DIR"
	# weston doesn't always land on wayland-0 (confirmed live this
	# session -- if an earlier instance's socket lock lingers, weston
	# picks the next free number instead). start-stop-daemon backgrounds
	# it either way; anything that needs WAYLAND_DISPLAY should glob
	# $XDG_RUNTIME_DIR/wayland-* rather than assume wayland-0.
	start-stop-daemon --start --background \
		--make-pidfile --pidfile /run/weston.pid \
		--exec /usr/bin/weston -- \
		--backend=drm-backend.so --log=/var/log/weston.log
	eend $?
}

stop() {
	ebegin "Stopping weston"
	start-stop-daemon --stop --pidfile /run/weston.pid
	eend $?
}
EOF
chmod +x "$rootdir/etc/init.d/weston"
ln -sf /etc/init.d/weston "$rootdir/etc/runlevels/default/weston"

# Serial console getty on the USB gadget console (ttyGS0), matching the
# bring-up ramdisk's own console -- OpenRC's default agetty.confd-style
# invocation via busybox's own getty applet (already in the base image).
if [ -f "$rootdir/etc/inittab" ]; then
	if ! grep -q ttyGS0 "$rootdir/etc/inittab"; then
		printf 'ttyGS0::respawn:/sbin/getty -L 115200 ttyGS0 vt100\n' >> "$rootdir/etc/inittab"
	fi
fi

echo "== building ext4 image =="
# Populate-at-creation (mke2fs -d), matching this project's existing
# "build a complete image, then dd it" pattern (boot/vendor_boot/etc).
# Sized to the SD partition created this session (~238 GiB, see
# docs/porting-log.md) with headroom subtracted -- override IMG_SIZE for
# a different target.
img="$outdir/alpine-root.img"
img_size=${IMG_SIZE:-8G}
rm -f "$img"
mke2fs -q -t ext4 -L alpine-root -d "$rootdir" "$img" "$img_size"

ls -la "$img"
echo "sha256: $(sha256sum "$img" | cut -d' ' -f1)"
