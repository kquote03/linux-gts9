#!/usr/bin/env bash
# Predates the ADSP/audio/sensor work entirely (see docs/distro-porting.md
# for the device-overlay split that came after this script was last
# touched) -- if reviving this, apply rootfs/overlay-common/ *and*
# rootfs/overlay-systemd/ (Ubuntu uses systemd too, so this one is a
# straight reuse, not a translation) and pull firmware from
# vendor-firmware-dump/firmware/qcom-sm8550/ the same way
# build-fedora-rootfs.sh does. Likely otherwise stale against the current
# kernel config too -- not touched since.
#
# Build a real Ubuntu 24.04 (noble) arm64 root filesystem -- Phase 4, the
# real distro rootfs that replaces the debug/Buildroot-Weston ramdisks
# entirely, booted from the microSD card (see docs/porting-log.md).
#
# Modeled on ubuntu-galaxy-tab-s9ultra/scripts/build-ubuntu-rootfs.sh (a
# real, working reference for this exact chip family) but adapted:
#   - `debootstrap`, not `mmdebstrap` -- mmdebstrap isn't packaged in this
#     nixpkgs snapshot (confirmed, see docs/hardware-facts.md's "Toolchain"
#     section); debootstrap is the documented substitute, already staged in
#     shell.nix and confirmed to actually run.
#   - No fingerprint/camera/sensor companion packages -- this port hasn't
#     brought up any of that hardware yet, unlike the sibling Ultra port.
#   - No `linux-image`/`initramfs-tools` inside the rootfs at all -- this
#     project's kernel lives entirely outside the rootfs, in the Android
#     boot chain's own `boot` partition, and its own from-scratch
#     `scripts/build-real-root-initramfs.sh` (reused as-is) is what
#     actually finds and switch_roots into this rootfs. A distro-generated
#     initramfs would never even run.
#   - Weston + weston-desktop-shell instead of GNOME Shell -- this board
#     has no GPU acceleration yet (Adreno/Turnip/freedreno never brought
#     up), and full GNOME Shell/Mutter effectively needs a working OpenGL
#     context. Weston's pixman software renderer is the exact stack
#     already proven rendering on this exact panel (Session 5).
#
# ## Two-stage debootstrap + qemu-user binfmt emulation
#
# Stage 1 (--foreign) just unpacks .debs on the host -- no target-arch
# execution needed. Stage 2 runs each package's postinst scripts *inside*
# the target, which needs to actually execute aarch64 code on this x86_64
# host. Confirmed live on this dev machine (not guessed):
#   - `debootstrap` runs via `nix-shell -p debootstrap` (mmdebstrap doesn't
#     exist in this nixpkgs snapshot).
#   - NixOS's own `aarch64-linux` binfmt_misc handler is already registered
#     and enabled (`cat /proc/sys/fs/binfmt_misc/aarch64-linux`) -- no
#     extra host setup needed for the emulation itself.
#   - That handler's flags are just `P` (no `F`/"fix binary"), so the
#     kernel resolves its interpreter path (`/run/binfmt/aarch64-linux`)
#     relative to *the calling process's own mount namespace* at exec
#     time -- which, after we `chroot` into the target, is the target's
#     own filesystem, not the host's. Confirmed the registered interpreter
#     itself is a genuinely static binary (`ldd` says "not a dynamic
#     executable") -- so the fix is simply copying that one file to the
#     identical path inside the target before running stage 2; no need to
#     bind-mount the whole Nix store in.
#   - This sandbox has no passwordless `sudo`, but `unshare --user
#     --map-root-user --mount` works (confirmed live) and grants real
#     `chroot()`/mount capability within its own private, unprivileged
#     user+mount namespace -- exits cleanly with zero leftover mounts on
#     the host when the wrapped command finishes, unlike a real bind-mount
#     done outside a private namespace. If run somewhere real `sudo` is
#     available instead, that works too -- either wrapper is fine, only
#     one is needed.
#
# ## What this script does NOT do
#
# Package selection beyond the small hand-picked base list below is done
# via a real `apt-get install` inside the chroot (proper dependency
# resolution), not stuffed into debootstrap's own weaker `--include`
# resolver -- debootstrap only builds a minimal base plus `apt` itself.
#
# Must run inside `nix-shell` (shell.nix) for `debootstrap`; the
# unshare/chroot/qemu machinery uses whatever's already on the host.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out/ubuntu}
rootdir=${ROOTFS_DIR:-$outdir/rootfs}
suite=${UBUNTU_SUITE:-noble}
mirror=${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
arch=arm64
hostname=${GTS9_HOSTNAME:-ubuntu-x716b}
username=${GTS9_USER:-ubuntu}

mkdir -p "$outdir"

if ! command -v debootstrap >/dev/null 2>&1; then
	echo "debootstrap not found -- run inside nix-shell (shell.nix already stages it)" >&2
	exit 1
fi

echo "== stage 1: debootstrap --foreign (host-side unpack, no emulation needed) =="
# debootstrap needs to chown/mknod as arbitrary system UIDs while unpacking
# -- real root or a mapped-root user namespace, same as stage 2 below
# (confirmed live: plain, unwrapped debootstrap fails outright with
# "debootstrap can only run as root" in this sandbox, which has no
# passwordless sudo).
debootstrap_path=$(command -v debootstrap)
if [ ! -e "$rootdir/debootstrap/debootstrap" ]; then
	rm -rf "$rootdir"
	mkdir -p "$rootdir"
	# --extractor=ar: debootstrap's default auto-detection picks "dpkg-deb"
	# whenever it thinks one might exist, but this environment (shell.nix)
	# has no real `dpkg`/`dpkg-deb` at all -- confirmed live (reproducing
	# the exact failure by hand: "dpkg-deb: command not found", which
	# debootstrap itself only surfaces as the much less specific "Tried to
	# extract package, but tar failed"). `ar` (from llvm.bintools, already
	# in shell.nix) is debootstrap's own alternative extractor for .deb
	# files (an .deb is an ar archive of control.tar.*/data.tar.*
	# members) and needs nothing dpkg-specific.
	unshare --user --map-root-user --mount --fork -- \
		"$debootstrap_path" --foreign --arch="$arch" --no-check-gpg \
		--extractor=ar \
		"$suite" "$rootdir" "$mirror"
else
	echo "using existing foreign-stage tree at $rootdir (rm -rf it to start clean)"
fi

echo "== staging qemu-aarch64 for the second stage =="
# Copy the exact binfmt_misc-registered interpreter to the identical path
# inside the target -- see the header comment for why this, not a bind
# mount, is enough (the registered handler is a static binary).
interp_line=$(sed -n 's/^interpreter //p' /proc/sys/fs/binfmt_misc/aarch64-linux 2>/dev/null || true)
if [ -z "$interp_line" ]; then
	echo "no aarch64-linux binfmt_misc handler registered on this host -- cannot run stage 2" >&2
	echo "(NixOS: boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];)" >&2
	exit 1
fi
mkdir -p "$rootdir$(dirname "$interp_line")"
cp "$interp_line" "$rootdir$interp_line"
# Also stage the conventional path (qemu-user-static's own package
# convention) in case anything inside the chroot looks for it there
# specifically, rather than relying on binfmt_misc alone.
mkdir -p "$rootdir/usr/bin"
cp "$interp_line" "$rootdir/usr/bin/qemu-aarch64-static"

echo "== stage 2: second-stage inside the chroot (real aarch64 execution, emulated) =="
run_in_chroot() {
	unshare --user --map-root-user --mount --pid --fork -- bash -c '
		set -e
		rootdir="$1"; shift
		mount -t proc proc "$rootdir/proc"
		mount --bind /sys "$rootdir/sys"
		mount --bind /dev "$rootdir/dev"
		mount --bind /dev/pts "$rootdir/dev/pts" 2>/dev/null || true
		chroot "$rootdir" "$@"
	' _ "$rootdir" "$@"
}

if [ ! -f "$rootdir/etc/debian_chroot" ]; then
	run_in_chroot /debootstrap/debootstrap --second-stage
	echo "$suite" > "$rootdir/etc/debian_chroot"
else
	echo "second stage already completed (found /etc/debian_chroot)"
fi

echo "== apt sources =="
mkdir -p "$rootdir/etc/apt"
cat > "$rootdir/etc/apt/sources.list" <<EOF
deb $mirror $suite main restricted universe multiverse
deb $mirror $suite-updates main restricted universe multiverse
deb $mirror $suite-security main restricted universe multiverse
EOF

echo "== installing the real package set via apt-get (proper dependency resolution) =="
# Base: minimal Ubuntu + systemd + our own already-proven WiFi/BT stack
# (NetworkManager/wpasupplicant for ath11k, bluez for hci_qca) + this
# project's established debugging toolset (matches the Buildroot rootfs's
# own list, buildroot/configs/x716_defconfig).
#
# Deliberately NOT installed: linux-image-*, initramfs-tools,
# grub*/systemd-boot -- see the header comment for why (no kernel or
# distro-generated initramfs lives in this rootfs at all).
base_packages="ubuntu-minimal ubuntu-standard \
sudo locales tzdata console-setup keyboard-configuration \
network-manager wpasupplicant bluez \
openssh-server \
e2fsprogs dosfstools parted \
iputils-ping curl wget ca-certificates \
nano less htop rsync unzip \
usbutils pciutils ethtool i2c-tools strace tree iw tcpdump"

# Desktop: Weston + weston-desktop-shell, the exact software-rendering
# stack already proven on this exact panel (Session 5) -- not GNOME Shell,
# see this script's header comment. Exact sub-package names for weston's
# bundled tools (terminal, desktop-shell) are confirmed live against
# noble's real archive at `apt-get install` time below, not guessed ahead
# of time -- if a name here doesn't exist, `apt-cache search weston`
# inside the chroot is the next step, not a re-guess.
desktop_packages="weston seatd"

run_in_chroot env DEBIAN_FRONTEND=noninteractive apt-get update
run_in_chroot env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	$base_packages $desktop_packages

echo "== identity / locale / keyboard =="
echo "$hostname" > "$rootdir/etc/hostname"
cat > "$rootdir/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$hostname
::1		localhost ip6-localhost ip6-loopback
EOF
echo 'en_US.UTF-8 UTF-8' > "$rootdir/etc/locale.gen"
echo 'LANG=en_US.UTF-8' > "$rootdir/etc/default/locale"
ln -sf /usr/share/zoneinfo/UTC "$rootdir/etc/localtime"
echo UTC > "$rootdir/etc/timezone"
run_in_chroot locale-gen

echo "== fstab (LABEL=, not a device path -- mmc device-letter order isn't stable" \
     " across boots, already confirmed this project) =="
cat > "$rootdir/etc/fstab" <<'EOF'
LABEL=ubuntu-root	/	ext4	defaults,noatime,errors=remount-ro	0 1
EOF

echo "== users =="
# Bring-up convenience, matching this project's existing pattern (the
# Buildroot rootfs's static dropbear root password, the Alpine attempt's
# static "alpine" password) -- not a production security posture.
run_in_chroot bash -c "echo 'root:tabs9root' | chpasswd"
if ! grep -q "^$username:" "$rootdir/etc/passwd"; then
	run_in_chroot useradd -m -s /bin/bash -G sudo,tty,audio,input,video "$username"
	run_in_chroot bash -c "echo '$username:tabs9root' | chpasswd"
fi

echo "== ssh =="
mkdir -p "$rootdir/etc/ssh/sshd_config.d"
cat > "$rootdir/etc/ssh/sshd_config.d/10-x716b.conf" <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

echo "== WiFi credentials (real file gitignored, same treatment as" \
     " buildroot/rootfs-overlay/etc/wpa_supplicant.conf) =="
nm_conn_dir="$rootdir/etc/NetworkManager/system-connections"
mkdir -p "$nm_conn_dir"
real_conn="$repo_root/buildroot/rootfs-overlay/etc/NetworkManager-system-connection.nmconnection"
if [ -f "$real_conn" ]; then
	cp "$real_conn" "$nm_conn_dir/home.nmconnection"
	chmod 600 "$nm_conn_dir/home.nmconnection"
else
	echo "warning: $real_conn not found -- no real WiFi profile seeded," \
		"see scripts/build-ubuntu-rootfs.sh.example.nmconnection" >&2
fi

echo "== weston (desktop-shell) systemd service =="
# Same invocation already proven working live on this exact hardware
# (Session 5, the Buildroot rootfs's own S99weston): DRM backend, pixman
# software renderer (no Mesa/GPU selected -- see header). A real graphical
# login isn't wired up (no display manager) -- weston starts directly as
# a systemd service on boot, matching the bring-up nature of this milestone.
cat > "$rootdir/etc/systemd/system/weston.service" <<'EOF'
[Unit]
Description=Weston Wayland compositor (DRM backend, pixman renderer)
After=systemd-user-sessions.service seatd.service
Wants=seatd.service

[Service]
Environment=XDG_RUNTIME_DIR=/run/weston
ExecStartPre=/bin/mkdir -p /run/weston
ExecStartPre=/bin/chmod 0700 /run/weston
ExecStart=/usr/bin/weston --backend=drm-backend.so --log=/var/log/weston.log
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
run_in_chroot systemctl enable weston.service
run_in_chroot systemctl enable NetworkManager.service
run_in_chroot systemctl enable bluetooth.service
run_in_chroot systemctl enable ssh.service

echo "== cleanup =="
run_in_chroot apt-get clean
rm -f "$rootdir/usr/bin/qemu-aarch64-static" "$rootdir$interp_line"

du -sh "$rootdir"
echo "rootfs directory ready at $rootdir -- next: tar it and push to the"
echo "microSD's freshly-formatted ext4 partition (see docs/porting-log.md)."
