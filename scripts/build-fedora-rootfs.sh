#!/usr/bin/env bash
# Build a Fedora 44 aarch64 root filesystem for the Samsung Galaxy Tab S9 5G
# (SM-X716B) -- gts9wifi-fedora pivot (Session 9, see docs/porting-log.md).
#
# Ported wholesale from gts9wifi-fedora/rootfs/build-rootfs.sh (a real,
# working reference for the Wi-Fi-only sibling tablet), per the Phase 3
# full-port pivot: the sensor stack (libssc/hexagonrpcd/pd-mapper/
# iio-sensor-proxy-over-SSC) is now built from source here too, same as
# their script does, plus the full device overlay (systemd units, udev
# rules, ALSA UCM, sleep hooks) -- see docs/porting-log.md's gts9wifi-fedora
# pivot entry for what got adapted vs. ported unchanged, and
# docs/distro-porting.md for why it's now split into rootfs/overlay-common/
# (applied by every rootfs builder) and rootfs/overlay-systemd/ (this
# builder's own init-system-specific half).
#
# One real architectural difference kept from their design, not from ours:
# their script bakes ADSP/HexagonFS firmware into the image from a
# separately-fetched firmware.tar.gz asset; this script does the same but
# sources it from this project's own scripts/extract-vendor-firmware.sh
# (vendor-firmware-dump/), which pulls directly off this exact device via
# TWRP rather than a prebuilt CI asset -- see that script's own comments
# for the apnhlos (ADSP PIL firmware)/dsp (HexagonFS skel libs) partition
# findings this depended on.
#
# ## Why this doesn't use podman (unlike gts9wifi-fedora's own script)
#
# Their script assumes either a real aarch64 CI runner or
# `podman run --platform=linux/arm64 quay.io/fedora/fedora:44 ...` locally.
# Tried that here first and it does NOT work on this dev machine:
# `podman run --platform=linux/arm64` pulls the real arm64 image fine, but
# every exec inside the container fails ("Exec format error") regardless
# of whether the interpreter is staged at the exact registered
# `/run/binfmt/aarch64-linux` path inside the image (confirmed by testing
# directly) -- podman's own container/mount-namespace setup does not
# consult this host's existing (non-container, NixOS-registered)
# binfmt_misc entry for processes it execs, and registering a NEW,
# container-visible binfmt handler (e.g. via
# `podman run --privileged multiarch/qemu-user-static --reset`) needs real
# root, which this sandbox does not have (confirmed: `sudo -n` fails).
#
# What DOES work, confirmed live: `dnf5 --forcearch=aarch64
# --installroot=...` run directly (no container) via `nix-shell -p dnf5`,
# wrapped in `unshare --user --mount` with a WIDE uid/gid mapping -- not
# just `--map-root-user`'s single 0->caller mapping, which is insufficient
# here (RPM %post scriptlets and `filesystem`'s own package content
# chown() to many distinct system UIDs, e.g. "mail" -- anything outside a
# single-ID map lands on the kernel's overflow UID on the real host view,
# which manifested as an inexplicable "chown failed - Device or resource
# busy" mid-transaction until this was found and fixed). This host's own
# `/etc/subuid`/`/etc/subgid` already carry a real 65536-ID range for this
# user (confirmed), used below via explicit `--map-users`/`--map-groups`
# ranges (0->caller for 1 ID, 1->subuid-base for 65536 more) -- the same
# convention rootless podman/buildah use internally, just done by hand
# here since podman's own container path didn't cooperate. The same
# interpreter-staging trick already used for the (superseded) Ubuntu
# debootstrap attempt handles the emulation itself: this host's registered
# `aarch64-linux` binfmt handler lacks the "F" (fix binary) flag, so its
# interpreter path is resolved from the calling process's own mount
# namespace at exec time -- copying that one (confirmed genuinely static)
# binary to the identical path inside the installroot is enough, no new
# registration needed.
#
# Real Fedora repo definitions (metalink URLs) are embedded directly
# below rather than extracted from a container image, since no container
# is used at all now -- these are the standard, official
# mirrors.fedoraproject.org URLs every Fedora system uses.
#
# Must run inside `nix-shell` (shell.nix already stages `dnf5`) for the
# actual build; the emulation/uid-mapping machinery uses whatever's
# already on this host (confirmed: this dev machine's own
# aarch64-linux binfmt_misc registration + wide subuid/subgid range).
set -euo pipefail

fedora_release="${FEDORA_RELEASE:-44}"
build_user="${GTS9_USER:-x716b}"
# gnome = full GNOME Workstation environment (matches the user's decision
#   to target a real GPU-accelerated desktop); core = @core-only, much
#   faster under qemu emulation -- build and boot-test this first as a
#   checkpoint before committing to the much larger, much slower GNOME
#   install (every package's %post runs emulated, not natively).
desktop="${GTS9_DESKTOP:-core}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out/fedora}
rootdir=${ROOTFS_DIR:-$outdir/rootfs}
cachedir=${DNF_CACHE:-$outdir/dnf-cache}
persistdir=${DNF_PERSIST:-$outdir/dnf-persist}
reposdir=${DNF_REPOS:-$outdir/dnf-repos}

mkdir -p "$rootdir" "$cachedir" "$persistdir" "$reposdir"

if ! command -v dnf5 >/dev/null 2>&1; then
	echo "dnf5 not found -- run inside nix-shell (shell.nix) or: nix-shell -p dnf5 --run 'bash $0'" >&2
	exit 1
fi

if [ -z "${SUBUID_BASE:-}" ]; then
	SUBUID_BASE=$(awk -F: -v u="$(id -un)" '$1==u{print $2}' /etc/subuid)
	SUBGID_BASE=$(awk -F: -v u="$(id -un)" '$1==u{print $2}' /etc/subgid)
fi
if [ -z "$SUBUID_BASE" ] || [ -z "$SUBGID_BASE" ]; then
	echo "no /etc/subuid or /etc/subgid range for $(id -un) -- required for the wide" >&2
	echo "uid/gid mapping this script's rootless dnf5 install needs (see header comment)" >&2
	exit 1
fi

echo "== writing real Fedora $fedora_release repo definitions =="
cat > "$reposdir/fedora.repo" <<EOF
[fedora]
name=Fedora \$releasever - \$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-\$releasever&arch=\$basearch
enabled=1
metadata_expire=7d
type=rpm
gpgcheck=0
skip_if_unavailable=False

[updates]
name=Fedora \$releasever - \$basearch - Updates
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f\$releasever&arch=\$basearch
enabled=1
metadata_expire=6h
type=rpm
gpgcheck=0
skip_if_unavailable=False
EOF

echo "== staging qemu-aarch64 interpreter at the exact registered path =="
interp_line=$(sed -n 's/^interpreter //p' /proc/sys/fs/binfmt_misc/aarch64-linux 2>/dev/null || true)
if [ -z "$interp_line" ]; then
	echo "no aarch64-linux binfmt_misc handler registered on this host" >&2
	exit 1
fi
# NOT $interp_line itself: confirmed via strace (Session 9) that NixOS's
# registered interpreter (a "...-binfmt-P" wrapper) is not actually
# self-contained -- despite `ldd` reporting it as static, it internally
# execve()s a *different*, specific /nix/store/.../qemu-user-.../
# qemu-aarch64 path at runtime (NixOS's own mechanism for implementing the
# "P" binfmt flag's argv semantics), which doesn't exist inside a bare
# chroot with no /nix bind-mounted -- every exec inside the installroot
# failed with a silent ENOENT on that inner path until this was found.
# `pkgsStatic.qemu-user`'s own qemu-aarch64 is a genuinely standalone
# static build (confirmed: `ldd` says "not a dynamic executable" AND it
# has no such internal re-exec) -- stage that instead, at the same
# registered path so the kernel's existing binfmt_misc match still finds
# it correctly.
# Provided by flake.nix's devShell (QEMU_AARCH64_STATIC) -- pinned there
# explicitly rather than left to PATH lookup, since `pkgsStatic.qemu-user`
# simply being installed alongside other packages wasn't enough (confirmed
# live: something else pulled in the plain, non-static `qemu-user` package
# transitively, shadowing it on PATH). Falls back to a direct `nix build`
# for anyone still using the old `nix-shell` (shell.nix) entry point.
real_static_interp=${QEMU_AARCH64_STATIC:-}
if [ -z "$real_static_interp" ] || [ ! -x "$real_static_interp" ]; then
	real_static_interp=$(nix-build --no-out-link -E \
		'with import <nixpkgs> {}; pkgsStatic.qemu-user' 2>/dev/null)/bin/qemu-aarch64
fi
if [ ! -x "$real_static_interp" ]; then
	echo "could not resolve a static qemu-aarch64 (pkgsStatic.qemu-user) -- run via 'nix develop' or nix-shell" >&2
	exit 1
fi
mkdir -p "$rootdir$(dirname "$interp_line")"
# rm -f first: a rerun against an already-populated $rootdir (e.g. after
# the dnf_install fault-tolerance fix below) would otherwise hit
# "Permission denied" -- the source is a read-only Nix store file and a
# plain `cp` over an existing copy of it preserves that read-only mode,
# which a later run's own unprivileged `cp` (outside the unshare wrapper)
# can't then overwrite.
rm -f "$rootdir$interp_line"
cp "$real_static_interp" "$rootdir$interp_line"

myuid=$(id -u)
mygid=$(id -g)

run_in_ns() {
	unshare --user \
		--map-users "0:$myuid:1" --map-users "1:$SUBUID_BASE:65536" \
		--map-groups "0:$mygid:1" --map-groups "1:$SUBGID_BASE:65536" \
		--mount --fork -- "$@"
}

# For chroot commands specifically: `chroot()` does NOT reset environment
# variables, only the filesystem root -- confirmed live (Session 9) that
# without this, PATH stays whatever this outer nix-shell environment set
# it to (a giant x86_64 Nix store path list that doesn't exist inside the
# aarch64 installroot at all), silently breaking every bare command name
# (the top-level one AND any subprocess a script spawns via its own PATH
# search, e.g. `chpasswd` invoked from inside `bash -c "... | chpasswd"`)
# with a misleading "command not found" that has nothing to do with the
# emulation itself. dnf5's own scriptlet execution already sets a correct
# PATH internally (confirmed: package installs above only hit 2 truly
# unrelated non-critical issues) -- this is only needed for this script's
# own direct chroot calls below.
run_chroot() {
	run_in_ns chroot "$rootdir" /usr/bin/env -i PATH=/usr/sbin:/usr/bin "$@"
}

dnf_install() {
	# --no-gpgchecks: same risk-acceptance already used for this
	# project's own debootstrap attempt (--no-check-gpg) -- packages
	# still only come from the real, HTTPS-fetched official Fedora
	# mirrors above, just without the extra RPM-signature layer, which
	# would otherwise need a real bootstrap-the-keys-first two-pass
	# dance (fedora-gpg-keys is itself one of the packages being
	# installed).
	#
	# `|| true`: confirmed live (first real @core run, Session 9) that
	# qemu-user emulation is unreliable for the syscalls modern
	# systemd-heavy RPM %post/%posttrans/%triggerin scriptlets make
	# (capability/cgroup/namespace operations qemu-user's process-level
	# translation doesn't fully support) -- dnf5 itself labels each of
	# these "Non-critical error" and keeps extracting every package's
	# real file content regardless, but still reports the overall
	# transaction as failed at the end. This is exactly the class of
	# problem gts9wifi-fedora's own README cites as the reason it
	# requires a real native-arm64 build environment ("no qemu, no
	# cross toolchain") -- accepted here per explicit user decision
	# (Session 9: "accept current output, test on real hardware" over
	# switching to full-system QEMU or pausing this work) rather than
	# treating it as silently fine. Whatever post-install state (sysusers,
	# ldconfig cache, tmpfiles) these scriptlets would have set up may be
	# stale or missing -- real first-boot verification on the actual
	# tablet (not this build log) is what actually answers whether that
	# matters, matching this project's standing "real signal, not
	# probe success" standard.
	run_in_ns dnf5 -y --installroot="$rootdir" --forcearch=aarch64 \
		--releasever="$fedora_release" \
		--setopt=reposdir="$reposdir" \
		--setopt=cachedir="$cachedir" \
		--setopt=persistdir="$persistdir" \
		--setopt=install_weak_deps=False --setopt=tsflags=nodocs \
		--no-gpgchecks "$@" || true
}

echo "== installing base packages =="
dnf_install install \
	@core \
	NetworkManager NetworkManager-wifi wpa_supplicant \
	openssh-server openssh-clients \
	sudo chrony zram-generator python3 \
	bluez bluez-tools \
	qrtr \
	alsa-ucm alsa-utils dtc \
	libqmi libqrtr-glib protobuf-c libmbim \
	systemd-pam \
	e2fsprogs kmod findutils \
	dbus-daemon dbus-x11

# Real Fedora package names for gts9wifi-fedora's own list (`atheros-
# firmware qcom-firmware`) are generic upstream WiFi/BT firmware blobs --
# deliberately NOT installed here, same reasoning as this project's
# existing GPU-firmware staging below: this device's own extracted,
# Samsung-signed blobs (vendor-firmware-dump/) are what its real hardware
# actually needs and accepts (TrustZone-signed images), not the generic
# upstream ones a Fedora meta-package would pull in.

# dbus-daemon/dbus-x11 added Session 9 after a real-hardware `dmesg`/
# `journalctl` capture (over the real serial getty, once that itself
# worked) showed gdm's wayland-session launcher failing in a hard loop
# ("Unable to run session message bus", "Session never registered,
# failing") -- traced to `dbus-run-session`/`dbus-launch` being entirely
# absent (`which` found nothing), even though the system bus
# (`dbus-broker`) itself was present and running fine. Fedora splits
# these into separate packages from `dbus-broker`, excluded here by
# `--setopt=install_weak_deps=False` since they're only weak/recommended
# dependencies, not hard ones -- same class of "weak-dep exclusion breaks
# something real" bug this project has hit before in other contexts. Real
# package names confirmed via `dnf provides` against the actual Fedora 44
# repo metadata (not guessed): `dbus-run-session` -> dbus-daemon,
# `dbus-launch` -> dbus-x11. Needed for any real login session (not just
# GNOME), so kept in the base list.

if [ "$desktop" = "gnome" ]; then
	echo "== installing the GNOME Workstation environment (slow under emulation) =="
	dnf_install install '@^workstation-product-environment'
	dnf_install remove gnome-initial-setup || true
	dnf_install install adwaita-mono-fonts adwaita-sans-fonts
	dnf_install install mesa-dri-drivers mesa-vulkan-drivers
fi

echo "== fixing DNS resolution inside the chroot (needed for the source builds below) =="
# dnf5 above resolves mirrors.fedoraproject.org from the *outer* host
# namespace (run_in_ns, not chroot'd), so it never needed this. But
# curl/git inside run_chroot's actual `chroot` genuinely use the target
# root's own /etc/resolv.conf -- and a fresh Fedora install's copy is a
# symlink to ../run/systemd/resolve/stub-resolv.conf, which does not
# exist inside this offline installroot (no systemd-resolved running here)
# -- confirmed live: "curl: Could not resolve host" for every source
# build below, immediately, before any real network attempt. Fixed by
# replacing the symlink with a real file pointing at the *host's* own
# resolver (127.0.0.53, systemd-resolved's stub listener) -- this works
# because run_in_ns only unshares user+mount namespaces, not network, so
# the chroot shares the exact same loopback interface as the host.
rm -f "$rootdir/etc/resolv.conf"
cp /etc/resolv.conf "$rootdir/etc/resolv.conf" 2>/dev/null || \
	echo 'nameserver 127.0.0.53' > "$rootdir/etc/resolv.conf"

echo "== installing native build dependencies (for the source builds below) =="
# Unlike gts9wifi-fedora's own script (a real native-arm64 CI runner, or a
# podman container targeting one), these compiles run inside the same
# qemu-user-emulated aarch64 chroot as everything else here -- slower, but
# the same mechanism already proven for dnf5 itself (see this script's
# header). Installed into the target root itself, not a separate build
# container, since this mechanism has no such separate stage.
dnf_install install \
	meson ninja-build gcc git curl tar patch make \
	pkgconf-pkg-config \
	glib2-devel libgudev-devel systemd-devel polkit-devel kmod \
	libqmi-devel protobuf-c-devel qrtr-devel xz-devel \
	python3-devel python3-protobuf

echo "== building libssc 0.4.4 (not in Fedora) =="
# Same source gts9wifi-fedora's own script and the postmarketOS port before
# it use -- provides libssc.so + ssccli, needed by iio-sensor-proxy's
# -Dssc-support=enabled build below.
run_chroot /usr/bin/bash -c '
	set -eu
	export HOME=/root
	d=$(mktemp -d)
	curl -sfL "https://codeberg.org/DylanVanAssche/libssc/archive/v0.4.4.tar.gz" \
		| tar xz -C "$d" --strip-components=1
	meson setup "$d/build" "$d" -Dprefix=/usr -Db_lto=true
	meson compile -C "$d/build"
	meson install --no-rebuild -C "$d/build"
'

echo "== building pd-mapper 1.1 (not in Fedora) =="
# Binary only: the sm8550 ADSP boots without service-registry JSONs (verified
# on the pmOS device this port is derived from). Ships its own systemd unit.
run_chroot /usr/bin/bash -c '
	set -eu
	export HOME=/root
	d=$(mktemp -d)
	curl -sfL "https://github.com/andersson/pd-mapper/archive/refs/tags/v1.1.tar.gz" \
		| tar xz -C "$d" --strip-components=1
	make -C "$d" prefix=/usr
	make -C "$d" install prefix=/usr
'

echo "== building hexagonrpcd 0.4.0 with Samsung patches =="
# Upstream tag + the three Samsung/port patches (large FastRPC inbufs;
# Samsung sensor-registry writes; Alpine's systemd-units patch) -- see
# specs/hexagonrpcd-samsung/ (ported from gts9wifi-fedora's identical
# directory, unchanged: these are genuine device-behavior fixes for
# "Samsung's SM8550 sensor firmware" in general per their own patch
# headers, not X710-specific).
patches_host="$repo_root/specs/hexagonrpcd-samsung/patches"
# The patch files themselves need to be reachable from inside the chroot;
# stage them at a /tmp path the chroot'd bash below can see (run_chroot's
# chroot already makes $rootdir/tmp the same directory as /tmp inside it)
# -- BEFORE the run_chroot call below that consumes them.
mkdir -p "$rootdir/tmp/hexagonrpcd-patches"
cp "$patches_host"/*.patch "$patches_host/10-fastrpc.rules" "$rootdir/tmp/hexagonrpcd-patches/"
run_chroot /usr/bin/bash -c '
	set -eu
	export HOME=/root
	d=$(mktemp -d)
	git clone -q --depth 1 --branch v0.4.0 https://github.com/linux-msm/hexagonrpc "$d/src"
	for p in /tmp/hexagonrpcd-patches/*.patch; do
		patch -d "$d/src" -p1 < "$p"
	done
	meson setup "$d/build" "$d/src" -Dprefix=/usr -Db_lto=true
	meson compile -C "$d/build"
	meson install --no-rebuild -C "$d/build"
	install -Dm644 /tmp/hexagonrpcd-patches/10-fastrpc.rules \
		-t /usr/lib/udev/rules.d/
	# The patch installs units to libdir/systemd/system, which lands in
	# usr/lib64 on Fedora -- a path systemd does not search. Move them
	# next to every other system unit (same fixup the gts9wifi-fedora
	# build script does).
	if [ -d /usr/lib64/systemd/system ]; then
		mkdir -p /usr/lib/systemd/system
		mv /usr/lib64/systemd/system/* /usr/lib/systemd/system/
		rmdir /usr/lib64/systemd/system /usr/lib64/systemd 2>/dev/null || true
	fi
'

# hexagonrpcd units run as the fastrpc system user (Alpine pre-install
# equivalent, matching gts9wifi-fedora's own build-rootfs.sh).
run_chroot /usr/sbin/groupadd -r fastrpc || true
run_chroot /usr/sbin/useradd -r -g fastrpc -s /usr/sbin/nologin -d / fastrpc || true

if [ "$desktop" = "gnome" ]; then
	# The Workstation environment installs Fedora's own iio-sensor-proxy
	# (kernel IIO backend only). Do NOT dnf-remove it: mutter/gnome-shell
	# require the package to exist and dnf-removing it cascades the whole
	# desktop out of the image. Drop just the rpmdb entry -- the
	# libssc-linked build below overwrites its files anyway.
	run_chroot /usr/bin/rpm -e --nodeps iio-sensor-proxy 2>/dev/null || true

	echo "== building iio-sensor-proxy 3.9 with libssc support =="
	mkdir -p "$rootdir/tmp/iio-sensor-proxy-patches"
	cp "$repo_root/specs/iio-sensor-proxy-libssc/patches/notify-slow-sensor-discovery.patch" \
		"$rootdir/tmp/iio-sensor-proxy-patches/"
	run_chroot /usr/bin/bash -c '
		set -eu
		export HOME=/root
		d=$(mktemp -d)
		curl -sfL "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/3.9/iio-sensor-proxy-3.9.tar.gz" \
			| tar xz -C "$d" --strip-components=1
		patch -d "$d" -p1 < /tmp/iio-sensor-proxy-patches/notify-slow-sensor-discovery.patch
		meson setup "$d/build" "$d" -Dprefix=/usr -Dssc-support=enabled
		meson compile -C "$d/build"
		meson install --no-rebuild -C "$d/build"
	'
fi
rm -rf "$rootdir/tmp/hexagonrpcd-patches" "$rootdir/tmp/iio-sensor-proxy-patches"

echo "== staging this project's own firmware (WiFi/BT/GPU) =="
# Reuses the exact files this project already extracted from this
# device's own /vendor/firmware (scripts/extract-vendor-firmware.sh) and
# staged for the Buildroot rootfs (scripts/fetch-ath11k-firmware.sh) --
# not gts9wifi-fedora's own firmware.tar.gz, which is for a different
# board in some cases (different WiFi/BT firmware naming, see the DTS
# comments in kernel/dts/sm8550-samsung-x716b.dts).
fwdir="$rootdir/usr/lib/firmware"
mkdir -p "$fwdir/qcom" "$fwdir/qca"
if [ -d "$repo_root/buildroot/firmware-overlay/lib/firmware" ]; then
	cp -a "$repo_root/buildroot/firmware-overlay/lib/firmware/." "$fwdir/"
else
	echo "    WARN: buildroot/firmware-overlay not built -- run scripts/fetch-ath11k-firmware.sh first" >&2
fi
vfw="$repo_root/vendor-firmware-dump/firmware"
# a740_sqe.fw added Session 9 after a real-hardware dmesg capture showed
# it -- not the zap-shader files -- was the one actually missing: "Direct
# firmware load for qcom/a740_sqe.fw failed with error -2" (the GPU's
# command-queue sequencer firmware, a separate blob from the zap shader).
# Already extracted into vendor-firmware-dump/ alongside the others.
for f in a740_zap.mdt a740_zap.b00 a740_zap.b01 a740_zap.b02 a740_sqe.fw gmu_gen70200.bin; do
	if [ -f "$vfw/$f" ]; then
		cp "$vfw/$f" "$fwdir/qcom/$f"
	else
		echo "    WARN: $vfw/$f not found -- GPU firmware will be incomplete" >&2
	fi
done

echo "== staging ADSP PIL firmware + HexagonFS payload + AudioReach topology =="
# Extracted by scripts/extract-vendor-firmware.sh (gts9wifi-fedora pivot),
# which itself pulls the device-specific firmware directly off this exact
# device's own apnhlos (ADSP PIL firmware, real Samsung-signed adsp.mdt +
# segments + adsp_dtb.mdt + segments -- confirmed real ELF/QUALCOMM DSP6
# via `file`) and dsp (userspace Hexagon FastRPC skel libraries, the real
# on-device source of gts9wifi-fedora's own "firmware-samsung-gts9wifi"
# payload concept) partitions, AND stages the AudioReach topology binary
# (not device-specific -- reused + one-token-patched from upstream
# linux-firmware.git, see stage-audioreach-topology.sh) into this same
# directory. Every rootfs builder gets all of it from one shared,
# distro-agnostic pipeline this way -- see that script's own comments for
# the real partition/filesystem findings and the topology reuse story.
mkdir -p "$fwdir/qcom/sm8550"
adspfw="$repo_root/vendor-firmware-dump/firmware/qcom-sm8550"
if [ -d "$adspfw" ] && [ -n "$(ls -A "$adspfw" 2>/dev/null)" ]; then
	# Whole directory, not an `adsp*` glob: that glob happened to catch
	# adspr.jsn/adsps.jsn/adspua.jsn (they start with "adsp") but silently
	# missed cdspr.jsn -- and more importantly, missing *any* of the four
	# PDR service-registry .jsn files here is exactly what left pd-mapper
	# permanently exiting "no pd maps available" and the sound card stuck
	# on "error getting cpu dai name" (see extract-vendor-firmware.sh's
	# comment on the same files -- root-caused and fixed live on hardware).
	# extract-vendor-firmware.sh only ever stages this exact allowlisted
	# set (plus the topology binary) into $adspfw, so copying the whole
	# directory is safe.
	cp "$adspfw"/* "$fwdir/qcom/sm8550/"
else
	echo "    WARN: $adspfw empty -- ADSP will not probe and the sound card will not instantiate (re-run scripts/extract-vendor-firmware.sh)" >&2
fi

# Install path matches this port's own choice in
# rootfs/overlay-systemd/etc/systemd/system/hexagonrpcd-adsp-sensorspd.
# service.d/10-gts9wifi-hexagonfs.conf's
# `-R` flag (/usr/share/qcom/sm8550/Samsung/gts9-5g) -- NOT gts9wifi-fedora's
# own "gts9wifi" path, since this is X716B's own extraction, not theirs.
hexagonfs_root="$rootdir/usr/share/qcom/sm8550/Samsung/gts9-5g"
mkdir -p "$hexagonfs_root/dsp"
hexfw="$repo_root/vendor-firmware-dump/hexagonfs/dsp/adsp"
if [ -d "$hexfw" ] && [ -n "$(ls -A "$hexfw" 2>/dev/null)" ]; then
	cp -a "$hexfw" "$hexagonfs_root/dsp/"
else
	echo "    WARN: $hexfw empty -- sensors/audio DSP userspace libs missing (re-run scripts/extract-vendor-firmware.sh)" >&2
fi

echo "== applying device overlay =="
# Split distro-agnostic/distro-specific per docs/distro-porting.md: apply
# both the shared data layer (ALSA UCM configs, udev rules, the dbus
# service file, plain POSIX shell scripts with no init-system assumptions
# -- every rootfs builder should apply this one) and Fedora's own
# systemd-specific layer (units, drop-ins, tmpfiles.d, the preset, and the
# handful of libexec scripts that call systemctl directly).
cp -a "$repo_root/rootfs/overlay-common/." "$rootdir/"
cp -a "$repo_root/rootfs/overlay-systemd/." "$rootdir/"

echo "== base system configuration =="
# fstab by LABEL, not UUID/device path -- matches this project's own
# already-confirmed finding (Networking/Storage bring-up sessions) that
# mmc device-letter enumeration order isn't stable across boots. Single
# ext4 root, no separate /boot -- the kernel/DTB/initramfs live in the
# Android boot chain, not on this filesystem (see this script's header).
cat > "$rootdir/etc/fstab" <<'EOF'
LABEL=x716b-root	/	ext4	defaults,noatime,errors=remount-ro	0 1
EOF
echo "x716b-fedora" > "$rootdir/etc/hostname"
if [ -f "$rootdir/etc/selinux/config" ]; then
	sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$rootdir/etc/selinux/config"
fi

# Pre-seed everything systemd-firstboot would otherwise ask for
# interactively on first boot (locale, keymap, timezone -- root's
# password is already set below, which alone is NOT enough to skip the
# prompt for the other fields). Confirmed live, Session 9: without this,
# first boot lands in a full-screen interactive TUI wizard -- and this
# board's USB controller is deliberately forced `dr_mode = "peripheral"`
# (Session 4, for the USB gadget serial console), so there is no real USB
# host/keyboard support to answer it with yet. Disabling
# systemd-firstboot.service outright (rather than only pre-seeding its
# files) is the robust fix -- matches systemd's own documented convention
# for pre-provisioned/image-based deployments.
echo 'LANG=en_US.UTF-8' > "$rootdir/etc/locale.conf"
echo 'KEYMAP=us' > "$rootdir/etc/vconsole.conf"
ln -sf /usr/share/zoneinfo/UTC "$rootdir/etc/localtime"
mkdir -p "$rootdir/etc/systemd/system"
ln -sf /dev/null "$rootdir/etc/systemd/system/systemd-firstboot.service"

echo "== WiFi credentials =="
# Same gitignored-real/tracked-placeholder pattern already established
# this project (buildroot/rootfs-overlay/etc/NetworkManager-system-
# connection.nmconnection/.example, built for the now-superseded Ubuntu
# attempt). Two profiles staged: "home" (the original network) and
# "guest" (an open network at a different location, added Session 9 when
# the tablet needed to be reachable somewhere else and USB host mode
# wasn't available yet for a local keyboard) -- both kept rather than
# replaced, so either location works without rebuilding.
nm_dir="$rootdir/etc/NetworkManager/system-connections"
mkdir -p "$nm_dir"
for profile in home:NetworkManager-system-connection.nmconnection \
	guest:NetworkManager-system-connection-guest.nmconnection; do
	name=${profile%%:*}
	file=${profile#*:}
	real_conn="$repo_root/buildroot/rootfs-overlay/etc/$file"
	if [ -f "$real_conn" ]; then
		install -m 0600 "$real_conn" "$nm_dir/$name.nmconnection"
	else
		echo "    WARN: $real_conn not found -- no real \"$name\" WiFi profile seeded" >&2
	fi
done

echo "== users =="
# Absolute paths (/usr/bin/bash, not bare "bash") AND run_chroot's clean
# PATH (not run_in_ns's raw chroot) -- see run_chroot's own comment: both
# the top-level command AND any subprocess a script spawns via its own
# PATH search (e.g. `chpasswd` invoked from inside `bash -c "... |
# chpasswd"`) need this, confirmed live (Session 9) both ways fail
# independently otherwise.
run_chroot /usr/bin/bash -c "echo 'root:${build_user}' | chpasswd"
# useradd's own skel copy can abort partway ("Bad file descriptor" on one
# entry -- confirmed live, Session 9, same quirk gts9wifi-fedora's own
# build-rootfs.sh independently documents hitting in its own CI
# container): populate the home directory explicitly instead of trusting
# useradd -m's skel copy to finish.
run_chroot /usr/sbin/useradd -M -G wheel -s /usr/bin/bash "$build_user" || true
run_chroot /usr/bin/bash -c "mkdir -p /home/${build_user} && cp -a /etc/skel/. /home/${build_user}/ && chown -R 1000:1000 /home/${build_user}"
run_chroot /usr/bin/bash -c "echo '${build_user}:${build_user}' | chpasswd"

echo "== enabling services =="
if [ "$desktop" = "gnome" ]; then
	run_chroot /usr/bin/systemctl enable gdm >/dev/null 2>&1 \
		|| echo "    WARN: gdm not found" >&2
	run_chroot /usr/bin/systemctl set-default graphical.target >/dev/null 2>&1 || true
	run_chroot /usr/bin/firewall-offline-cmd --add-service=ssh >/dev/null 2>&1 \
		|| echo "    WARN: could not allow ssh in the firewall" >&2
fi
for unit in sshd NetworkManager bluetooth; do
	run_chroot /usr/bin/systemctl enable "$unit" >/dev/null 2>&1 \
		|| echo "    WARN: unit not found: $unit" >&2
done

# rmtfs arrives as a preset-enabled neighbour of qrtr but this board has no
# modem remoteproc; left enabled it restart-loops forever ("Failed to get
# rprocfd"), matching gts9wifi-fedora's own finding verbatim.
run_chroot /usr/bin/systemctl mask rmtfs.service >/dev/null 2>&1 || true

# The device stack from rootfs/overlay-common/ + rootfs/overlay-systemd/
# (gts9wifi-fedora pivot, ported wholesale -- unit *names* kept
# gts9wifi-*-prefixed per the plan, only content adapted where X716B's own
# facts genuinely differ, see docs/porting-log.md). Deliberately NOT
# enabled here, matching gts9wifi-fedora's own hard-won finding (their
# build-rootfs.sh's own comment, carried into
# rootfs/overlay-systemd/usr/lib/systemd/system-preset/85-gts9wifi.preset
# verbatim):
#  - hexagonrpcd-adsp-sensorspd: pulls in gts9wifi-adsp-boot via the
#    hexagonfs drop-in's Requires=; the ADSP start can hang or reset the
#    SoC, and doing it while panel-coldboot-recover's pm_test suspend runs
#    froze the board completely. Start it manually and watch.
#  - gts9wifi-adsp-boot.service: same, ships disabled upstream too.
#  - gts9wifi-bt-revive.service: started by hand when the WCN sequencer
#    takes hci0 down.
#  - vendor.mount / gts9wifi-android-parts.service: full /vendor (erofs
#    super partition) needs a dynamic-partition dm-mapping tool
#    (`make-dynpart-mappings`) neither this project nor gts9wifi-fedora
#    has ported (their own docs/PORT-KIT.md lists this as an explicit
#    TODO) -- not needed for anything this port's own feature set uses
#    (dsp/apnhlos/persist mount directly by real partlabel instead, no
#    dynamic-partition mapping required).
#  - gts9wifi-mem-reclaim: NOT ported at all (removed from the overlay
#    here) -- it targets Samsung's downstream reserved-memory carveout
#    names (mpss-region@..., sec-qcom-rdx@..., trust-ui-vm-*, ...), none
#    of which exist in this project's own mainline board DTB to begin
#    with (we never carried those carveouts, unlike a stock Android boot
#    chain would) -- the memory this script reclaims on gts9wifi-fedora's
#    boot images was never wasted on ours, so there's nothing for it to do.
for unit in \
	hexagonrpcd-adsp-rootpd \
	pd-mapper \
	gts9wifi-wait-sensor-proxy \
	gts9wifi-bt-provision \
	gts9wifi-panel-coldboot-recover \
	gts9wifi-grow-rootfs \
	gts9wifi-usb-net gts9wifi-wifi-recover gts9wifi-sensor-registry-perms \
	gts9wifi-x11-dir-fix.path gts9wifi-chronyd \
	mnt-vendor-persist.mount vendor-dsp.mount vendor-firmware_mnt.mount
do
	run_chroot /usr/bin/systemctl enable "$unit" >/dev/null 2>&1 \
		|| echo "    WARN: unit not found: $unit" >&2
done

# Real login prompt on the USB gadget serial console (ttyGS0), matching
# this project's standing "keep the serial console active always" -- kept
# as a fallback even now that WiFi/SSH is the primary channel. `console=
# ...console=ttyGS0,115200` (last on the kernel cmdline, so it's the
# primary /dev/console) is already set by
# scripts/build-android-v4-bundle.sh, and CONFIG_USB_G_SERIAL=y is
# already forced built-in.
#
# NOT systemd's own `serial-getty@.service` template -- confirmed live
# (Session 9) it never actually starts here: it carries
# `BindsTo=dev-%i.device`, which needs systemd/udev to generate a matching
# `dev-ttyGS0.device` unit, and that dependency is never satisfied for
# this gadget tty (created early by scripts/build-real-root-initramfs.sh's
# own devtmpfs, before the real rootfs's udev instance ever runs a
# coldplug over it post-switch_root) -- the getty just waits forever with
# zero output, not a crash, which is why this was hard to diagnose without
# pulling the persistent systemd journal directly via TWRP. Fixed with a
# small custom unit that has no device-unit dependency at all.
cat > "$rootdir/etc/systemd/system/x716b-serial-getty.service" <<'EOF'
[Unit]
Description=Serial getty on ttyGS0 (USB gadget console, no device-unit dependency)
Documentation=man:agetty(8)
After=multi-user.target

[Service]
# Confirmed live (gts9wifi-fedora pivot, this exact unit): the arg order
# above was wrong -- verified against systemd's own real upstream
# serial-getty@.service.in template (`agetty ... %I $TERM`, port name in
# the FIRST positional slot, no leading "-"). With "- ttyGS0" instead,
# agetty's first positional arg is `-` (fine, a real agetty convention
# meaning "use the already-attached stdio", matching TTYPath=/
# StandardInput=tty below), but the SECOND positional arg lands in the
# baud_rate slot -- and "ttyGS0" is not a valid baud rate, so agetty
# fails argument validation and exits immediately, every time, in a
# silent Restart=always/RestartSec=1 loop that produces zero output on
# the actual serial line (the failure only ever reaches the journal,
# which nothing here was reading). This is what made the very first real
# post-pivot boot look completely dead on the serial console despite a
# real, healthy Fedora login prompt on the panel (tty1) the whole time.
ExecStart=-/usr/sbin/agetty --keep-baud 115200 ttyGS0 $TERM
Type=idle
Restart=always
RestartSec=1
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/ttyGS0
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$rootdir/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/x716b-serial-getty.service \
	"$rootdir/etc/systemd/system/multi-user.target.wants/x716b-serial-getty.service"

echo "== cleaning =="
rm -rf "$rootdir/var/cache/dnf" "$rootdir/var/cache/rpm" "$rootdir"/var/log/dnf*
rm -f "$rootdir/etc/machine-id" "$rootdir/var/lib/systemd/random-seed"
rm -f "$rootdir$interp_line"
# Each source build above (libssc/pd-mapper/hexagonrpcd/iio-sensor-proxy)
# does its own `d=$(mktemp -d)` *inside* the chroot -- i.e. under
# $rootdir/tmp -- and none of those blocks ever `rm -rf "$d"` afterward.
# Confirmed live (first real build of this stack): the packed archive
# carried every one of those source/build trees intact, real bloat with
# no functional purpose (the final installed binaries/libs are already
# staged at their real paths by `meson install`/`make install`). Strip
# them here rather than patching each build block individually.
find "$rootdir/tmp" -maxdepth 1 -name 'tmp.*' -exec rm -rf {} + 2>/dev/null || true

echo "== packing =="
archive="$outdir/x716b-fedora-$fedora_release-$desktop-rootfs.tar.gz"
# Wrapped in run_in_ns: real shadow/gshadow/sudo/home-directory content
# is only readable as the mapped "root" this whole build has run as
# (confirmed live, Session 9 -- our real, unprivileged outer user can't
# read these files directly, same reasoning as every other step here).
run_in_ns tar -C "$rootdir" --numeric-owner -czf "$archive" .

echo "== done: $archive =="
ls -la "$archive"
echo "sha256: $(sha256sum "$archive" | cut -d' ' -f1)"
