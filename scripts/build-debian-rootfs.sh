#!/usr/bin/env bash
# Build a reproducible Debian unstable (sid) aarch64 root filesystem for
# the Samsung Galaxy Tab S9 5G (SM-X716B) -- the third rootfs target on
# this port, after Fedora (scripts/build-fedora-rootfs.sh) and NixOS
# (nixos/). Implements the docs/distro-porting.md contract: apply
# rootfs/overlay-common/ and rootfs/overlay-systemd/ verbatim (Debian is
# systemd + merged-/usr by sid, so -- unlike NixOS -- this needs no
# translation layer at all, same situation as Fedora), stage this
# project's own vendor firmware, build the Qualcomm sensor/ADSP stack
# from the exact same source pins Fedora/NixOS use, and trigger ALSA UCM.
#
# Desktop: a REAL, GPU-accelerated KDE Plasma 6 on Wayland (task-kde-
# desktop -> kde-standard, SDDM). This is deliberately not a repeat of
# the older build-ubuntu-rootfs.sh's Weston/software-rendering choice --
# that was correct when written ("no GPU acceleration yet"), but the
# NixOS session this port just finished booted real Plasma 6 on Wayland
# via SDDM on this exact kernel .config (DRM_MSM/FB/VT all already =y,
# confirmed sufficient there) -- so Debian gets the real thing too.
#
# ## Reproducibility: snapshot.debian.org, not the live unstable mirror
#
# "Debian unstable" is a rolling target by definition -- the same
# `apt-get install` command run today and in six months resolves to
# different package versions against the live archive. Both debootstrap
# AND every later `apt-get install` here point at a snapshot.debian.org
# URL with a FIXED timestamp ($DEBIAN_SNAPSHOT below) instead, so
# re-running this script -- on this machine or any other -- always
# resolves the identical package set. Bumping the snapshot forward is
# then a deliberate, one-line act, never silent drift. This is a
# *stronger* reproducibility story than build-fedora-rootfs.sh's own
# (which is honest that its live dnf mirror content isn't pinned at all)
# -- see docs/distro-porting.md.
#
# Snapshot Release files are the real, signed Debian archive Release
# files (verified live: fetching one back shows real Origin/Label/
# Architectures/Components fields, signed with the real archive keys) --
# apt's normal signature verification stays ON. Two things still need
# disabling, both narrowly scoped and documented, matching this
# project's existing risk-acceptance precedent (build-ubuntu-rootfs.sh's
# own --no-check-gpg for the exact same reason):
#   - debootstrap's own --no-check-gpg: its bootstrap-phase verification
#     runs before debian-archive-keyring is even installed in the target,
#     so it has nothing to check against yet regardless.
#   - check-valid-until=no on the sources.list entries: a frozen snapshot
#     is, by construction, older than its own Release file's Valid-Until
#     -- that field exists to catch a *stale mirror*, not a *deliberately
#     pinned* one.
#
# ## Two-stage debootstrap + qemu-user emulation via proot (NOT chroot)
#
# Stage 1 (--foreign) unpacks .debs on the host, no target-arch execution
# needed -- same as build-ubuntu-rootfs.sh, still run inside `unshare
# --user` with a WIDE subuid/subgid range mapping (a single --map-root-user
# 0<->caller mapping is not enough: confirmed live, stage 1 dies extracting
# libpam-modules-bin, "Cannot change ownership to uid 0, gid 318: Invalid
# argument" -- unix_chkpwd is setgid to a real non-0 group with no mapping
# in a single-uid namespace).
#
# Stage 2 (--second-stage) is where this script genuinely departs from
# build-ubuntu-rootfs.sh's chroot()-based scaffold. Confirmed live, the
# hard way, in this exact sandbox: chroot(2) itself is unconditionally
# blocked here -- every invocation, even `chroot "$rootdir" /bin/true`
# with no qemu/emulation involved at all, returns exit 255 with zero
# output of any kind (no error text, nothing). Isolated testing (`strace
# -f`) ruled out a missing-binary or environment problem; this is a
# container-level restriction on the chroot(2) syscall itself, the same
# class of restriction already found and worked around for whole-/sys and
# whole-/dev bind mounts and for mknod(2) elsewhere in this build
# environment. There is no narrower fix for a blocked syscall -- the whole
# mechanism has to change.
#
# proot(1) is that change: a pure ptrace-based path-translation layer that
# reimplements chroot/bind-mount/binfmt semantics entirely in userspace,
# needing neither chroot(2) nor mount(2). Confirmed live: `proot -b /proc
# -b /sys -b /dev -r "$rootdir" -0 -q "$QEMU_AARCH64_STATIC" ...` runs the
# real aarch64 target binaries (via qemu-user, since the host is x86_64)
# with a believable fake root identity (-0), and its -b binds are pure
# ptrace path rewrites -- not real mount(2) calls -- so they hit none of
# the mount restrictions documented elsewhere in this script. This also
# works completely unprivileged: proot fakes chown/chmod/mknod results at
# the ptrace layer rather than performing them for real, so run_in_chroot
# below no longer needs (or uses) any uid/gid mapping trick of its own --
# only stage 1's plain tar-based extraction still does.
#
# $QEMU_AARCH64_STATIC (root flake.nix's commonEnv) is a genuinely
# statically-linked, musl-built qemu-aarch64 -- confirmed via `ldd`/`file`
# -- unlike nixpkgs's plain `qemu-user` package, whose dynamically-linked
# build pulls in a long, easy-to-break transitive .so closure (hit this
# live: cascading "cannot open shared object file" for libp11-kit then
# libidn2). It is NOT the same binary as the host's own registered
# aarch64-linux binfmt_misc interpreter (a "-P"/argv0-preserving build
# meant only for direct kernel binfmt invocation, confirmed live to
# mis-parse proot's own `-q`-constructed argv, e.g. "Error while loading
# -U: No such file or directory") -- don't swap the two.
#
# `-b /nix:/nix` is also required: nixpkgs's debootstrap derivation runs
# patchShebangs over every file it installs, including the /debootstrap/
# debootstrap template that gets copied VERBATIM into the target and is
# meant to run there post-chroot with the target's own /bin/sh -- but
# patchShebangs rewrote its shebang to the HOST's own nix-store bash path
# regardless (confirmed live: "#!/nix/store/.../bash" on a file meant for
# guest execution), and that same generated script also hardcodes an
# absolute host nix-store path to the dpkg binary used during stage 1.
# Rather than patch every such host-path leak individually (there could be
# more), binding /nix into the guest makes all of them resolve
# transparently. The one shebang line still needs a manual fix (below) --
# it's baked into the file at generation time, not just referenced from
# it, so no bind mount fixes it.
#
# ## Known, confirmed-live qemu-user flakiness during early dpkg bootstrap
#
# Beyond the already-documented general risk (postinst scripts + qemu-user
# emulation, below), stage 2 specifically was observed live to sometimes
# abort a package's maintainer script outright ("Aborted (core dumped)",
# "malloc(): corrupted top size", or similar) during the very first
# handful of packages (dpkg/base-files/libc6) -- nondeterministically: the
# exact same invocation against a freshly re-extracted rootdir succeeded
# cleanly on a later attempt with zero code changes. This is qemu-user's
# own emulation instability, not a logic bug in this script. Critically,
# debootstrap's --second-stage is NOT safely re-runnable in place after
# such a crash: it writes its own minimal dpkg status bootstrap stub
# unconditionally at the top of the script, so a second invocation against
# the same half-crashed $rootdir corrupts /var/lib/dpkg/status further
# (confirmed live: duplicate/malformed "Package: dpkg" stanzas, "multiple
# non-coinstallable package instances present"), not fewer. The only
# reliable recovery, confirmed live, is a clean re-extraction: wipe
# $rootdir and redo stage 1 (cheap -- host-side tar extraction, no
# emulation) before retrying stage 2. stage2_with_retries() below does
# exactly that, bounded, and only for this specific narrow step -- it does
# not paper over failures anywhere else in this script.
#
# ## What this script does NOT do
#
# No linux-image-*/initramfs-tools/grub* -- this project's kernel lives
# entirely in the Android boot chain's own `boot` partition, and
# scripts/build-real-root-initramfs.sh's own busybox switch_root (reused
# as-is, unchanged) is what finds and boots into this rootfs, by
# filesystem LABEL=X716B_ROOT -- not a Debian-specific label, deliberately,
# so this rootfs is a drop-in target for scripts/deploy-rootfs.sh's
# existing sd/twrp-sd/userdata paths and the boot bundle already flashed
# for Fedora/NixOS, with zero boot-chain changes.
#
# Package selection beyond the hand-picked base list is done via a real
# `apt-get install` inside the chroot for proper dependency resolution,
# not debootstrap's own weaker --include resolver (same reasoning as
# build-ubuntu-rootfs.sh) -- debootstrap only builds --variant=minbase.
#
# ## Known risk: qemu-user emulation and package postinst scripts
#
# build-fedora-rootfs.sh's own dnf_install() comment records, confirmed
# live, that qemu-user emulation is unreliable for systemd-heavy package
# post-install scriptlets (capability/cgroup/namespace syscalls its
# process-level translation doesn't fully support) -- dnf5 labels these
# "Non-critical error" and keeps extracting real file content regardless,
# but the overall transaction still reports failed. `dpkg`'s own postinst
# scripts (deb-systemd-helper unit enablement, udevadm trigger, ldconfig,
# etc.) are the same class of risk under the same emulation. apt-get
# install calls below are NOT wrapped in `|| true` the way Fedora's are --
# confirm live whether that's actually needed here before adding it
# reflexively; either way, a clean-looking build log is not proof of a
# working image -- real verification is booting this on the tablet (see
# docs/porting-log.md's staged-validation entries for every other
# rootfs), not this build log.
#
# Must run inside `nix develop` (root flake.nix already stages
# debootstrap + the aarch64 cross toolchain's binfmt prerequisites); the
# unshare/chroot/qemu machinery uses whatever's already on the host.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out/debian}
rootdir=${ROOTFS_DIR:-$outdir/rootfs}

# Pin: bump deliberately, not silently. Verified live (this session) that
# snapshot.debian.org serves a real signed unstable snapshot at this
# timestamp (arm64 included) -- see docs/porting-log.md.
snapshot=${DEBIAN_SNAPSHOT:-20260901T000000Z}
mirror="https://snapshot.debian.org/archive/debian/$snapshot/"
suite=unstable
arch=arm64
hostname=${GTS9_HOSTNAME:-debian-x716b}
username=${GTS9_USER:-x716b}
# core = minimal base + our device stack, no desktop (fast checkpoint);
# kde = + task-kde-desktop (kde-standard scope, real GPU-accelerated
# Plasma 6 on Wayland). Matches the Fedora script's own GTS9_DESKTOP
# core/gnome toggle.
desktop=${GTS9_DESKTOP:-kde}

mkdir -p "$outdir"

if ! command -v debootstrap >/dev/null 2>&1; then
	echo "debootstrap not found -- run inside 'nix develop'" >&2
	exit 1
fi

myuid=$(id -u)
mygid=$(id -g)
subuid_base=$(awk -F: -v u="$(id -un)" '$1==u{print $2}' /etc/subuid | head -1)
subgid_base=$(awk -F: -v g="$(id -gn)" '$1==g{print $2}' /etc/subgid | head -1)
: "${subuid_base:=100000}" "${subgid_base:=100000}"

if ! command -v proot >/dev/null 2>&1; then
	echo "proot not found -- run inside 'nix develop' (flake.nix's devPackages)" >&2
	exit 1
fi
if [ -z "${QEMU_AARCH64_STATIC:-}" ] || [ ! -x "$QEMU_AARCH64_STATIC" ]; then
	echo "QEMU_AARCH64_STATIC not set/executable -- run inside 'nix develop'" >&2
	exit 1
fi
if [ -z "${SYSTEMD_SYSUSERS_HOST:-}" ] || [ ! -x "$SYSTEMD_SYSUSERS_HOST" ]; then
	echo "SYSTEMD_SYSUSERS_HOST not set/executable -- run inside 'nix develop'" >&2
	exit 1
fi
if [ -z "${SYSTEMD_TMPFILES_HOST:-}" ] || [ ! -x "$SYSTEMD_TMPFILES_HOST" ]; then
	echo "SYSTEMD_TMPFILES_HOST not set/executable -- run inside 'nix develop'" >&2
	exit 1
fi

run_in_ns() {
	# A plain --map-root-user (uid/gid 0 only) is NOT enough: confirmed
	# live, stage 1 itself dies extracting libpam-modules-bin
	# ("Cannot change ownership to uid 0, gid 318: Invalid argument" --
	# unix_chkpwd is setgid to the real `shadow` group, gid 318 in this
	# snapshot, which has no mapping in a single-uid namespace). Same
	# class of problem build-fedora-rootfs.sh's wide subuid/subgid range
	# solves for RPM's own non-root-owned files.
	unshare --user \
		--map-users "0:$myuid:1" --map-users "1:$subuid_base:65536" \
		--map-groups "0:$mygid:1" --map-groups "1:$subgid_base:65536" \
		--mount --fork -- "$@"
}

debootstrap_path=$(command -v debootstrap)

stage1() {
	echo "== stage 1: debootstrap --foreign (host-side unpack, no emulation needed) =="
	# run_in_ns, not a plain rm -rf: confirmed live, a rerun against a
	# rootdir that has already been through seed_sysusers/seed_tmpfiles
	# (both run_in_ns-wrapped, real chown to real mapped uids like
	# systemd-network) leaves files this script's own plain unprivileged
	# invocation cannot remove ("Permission denied") -- the SAME wide
	# subuid/subgid mapping that created them is needed to remove them
	# again.
	run_in_ns rm -rf "$rootdir"
	mkdir -p "$rootdir"
	run_in_ns "$debootstrap_path" --foreign --arch="$arch" --variant=minbase \
		--no-check-gpg --extractor=ar \
		--components=main,contrib,non-free-firmware,non-free \
		"$suite" "$rootdir" "$mirror"

	# nixpkgs's debootstrap derivation's patchShebangs pass rewrote this
	# generated-for-the-target script's shebang to the HOST's own
	# nix-store bash path -- confirmed live. It's meant to run inside the
	# guest, via the guest's own /bin/sh (already present at this point,
	# dash); fix the one line patchShebangs got wrong. See the header for
	# the full story, including why -b /nix:/nix below is still needed
	# for the other host-path leak (the DPKG= variable) in this same
	# file.
	sed -i '1s|^#!.*|#!/bin/sh|' "$rootdir/debootstrap/debootstrap"
}

# run_in_chroot_once: proot, not chroot -- see the header for why chroot(2)
# is unconditionally unusable in this build environment. No uid/gid mapping
# needed here (unlike stage 1's run_in_ns): proot's -0 fakes root and
# fakes the results of chown/chmod/mknod entirely at the ptrace layer, it
# never needs real extended privilege for that.
run_in_chroot_once() {
	proot \
		-b /proc -b /sys -b /dev -b /nix:/nix \
		-r "$rootdir" -0 -w / \
		-q "$QEMU_AARCH64_STATIC" \
		/usr/bin/env -i \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive \
		"$@"
}

# seed_sysusers / seed_tmpfiles: run the HOST's own NATIVE
# ($SYSTEMD_SYSUSERS_HOST / $SYSTEMD_TMPFILES_HOST, x86_64, no qemu/proot
# involved at all) copies of these tools directly against $rootdir. Both
# need run_in_ns's wide subuid/subgid mapping (the SAME reason stage 1
# needs it): confirmed live, a plain unprivileged host invocation gets
# every single fchownat() in systemd-tmpfiles --create rejected with
# "Operation not permitted" (real root-owned paths, real host process, no
# privilege to become root for real) -- inside run_in_ns's mapped
# namespace, every one of those succeeds instead.
#
# seed_sysusers is used reactively, from run_in_chroot's retry loop below,
# to work around a confirmed-live proot crash ("path.c:547:
# compare_paths2: Assertion `length2 > 0' failed", SIGABRT -- a known,
# long-standing, still-unfixed upstream proot limitation, e.g. termux/
# proot#123/#159, proot-me/proot#182) that fires when the guest's
# (qemu-emulated) systemd-sysusers tries to create a genuinely NEW system
# user. Confirmed live it does NOT crash re-run against users that already
# exist (idempotent no-op path) -- so seeding for real from the host
# first, then letting the guest's own later call find everything already
# present, avoids the crash entirely.
#
# seed_tmpfiles is used differently -- NOT reactively in the retry loop.
# Confirmed live, the hard way: systemd-tmpfiles --create crashes proot
# the exact same way UNCONDITIONALLY, even when there is nothing left to
# create (re-verified against an already-fully-seeded rootdir -- same
# crash, same line, every time). Pre-seeding cannot make the guest's own
# call safe the way it does for sysusers. The actual fix is the
# systemd-tmpfiles dpkg diversion below, which stops the guest from ever
# executing the real binary at all during package installation --
# seed_tmpfiles is called exactly once, at the very end of this script,
# to do the real work for real after every package is already installed
# and the diversion is lifted.
#
# One narrow correctness gap in $SYSTEMD_SYSUSERS_HOST, confirmed live
# and fixed here, that does not affect any other field (UID/GID/comment/
# home all confirmed correct): it does not consistently chase the
# "nologin" shell keyword through --root -- it can write the HOST's own
# /nix/store/.../bin/nologin path into the TARGET's /etc/passwd instead of
# /usr/sbin/nologin (meaningless on the shipped image, that store path
# doesn't exist there). Fixed with a sed pass.
seed_sysusers() {
	run_in_ns "$SYSTEMD_SYSUSERS_HOST" --root="$rootdir" 2>&1 \
		| grep -v 'Failed to chase and open directory.*sysusers.d.*Permission denied' >&2 || true
	sed -i 's#:/nix/store/[^:]*/bin/nologin$#:/usr/sbin/nologin#' "$rootdir/etc/passwd"
}
seed_tmpfiles() {
	# One narrow tolerated failure, confirmed live and harmless: one ACL
	# assignment (`g:4294967295:r-x` on /var/log/journal -- an
	# unresolvable/overflowed GID, itself a sign the "adm" group name
	# didn't resolve correctly through --root either) fails with EINVAL.
	# Only affects the "adm" group's read access to the journal
	# directory, not anything boot-critical.
	run_in_ns "$SYSTEMD_TMPFILES_HOST" --root="$rootdir" --create 2>&1 \
		| grep -v 'Setting access ACL.*journal.*failed: Invalid argument' >&2 || true
}

# run_in_chroot: run_in_chroot_once with a bounded retry, seeding sysusers
# from the host (see seed_sysusers above -- confirmed to actually work for
# THIS specific crash, unlike seed_tmpfiles, see above) before every
# retry. The retry loop itself also stays as a second, independent safety
# net for the separate, genuinely nondeterministic qemu-user postinst-
# script flakiness already documented in this script's header -- `dpkg
# --configure -a` is the standard, supported way to finish a package left
# half-configured by an interrupted transaction (dpkg's database is
# transactional per .deb; no special bootstrap-stub logic involved here,
# unlike debootstrap's own --second-stage -- see stage2's own retry loop
# above, which needs a harsher clean-re-extraction recovery instead).
run_in_chroot() {
	local attempt=1 max_attempts=10
	while :; do
		if run_in_chroot_once "$@"; then
			return 0
		fi
		attempt=$((attempt + 1))
		if [ "$attempt" -gt "$max_attempts" ]; then
			echo "run_in_chroot: '$*' failed $max_attempts times in a row -- giving up" >&2
			return 1
		fi
		echo "run_in_chroot: '$*' failed (attempt $((attempt - 1))/$max_attempts) --" \
		     " seeding sysusers from the host and repairing via" \
		     " 'dpkg --configure -a' before retrying (see seed_sysusers" \
		     " above and this script's header)" >&2
		seed_sysusers
		run_in_chroot_once dpkg --configure -a || true
	done
}

if [ ! -e "$rootdir/debootstrap/debootstrap" ]; then
	stage1
else
	echo "using existing foreign-stage tree at $rootdir (rm -rf it to start clean)"
fi

echo "== stage 2: second-stage under proot (real aarch64 execution, emulated) =="
# Bounded retry, each attempt from a CLEAN stage-1 extraction -- see the
# header's "Known, confirmed-live qemu-user flakiness" section for why an
# in-place retry against a half-crashed $rootdir is unsafe (it corrupts
# /var/lib/dpkg/status further, not less) and why a clean re-extraction is
# the only confirmed-reliable recovery.
if [ ! -f "$rootdir/etc/debian_chroot" ]; then
	max_attempts=5
	attempt=1
	while :; do
		if [ "$attempt" -gt 1 ]; then
			echo "stage 2 attempt $attempt/$max_attempts (previous attempt's dpkg" \
			     " aborted mid-postinst -- confirmed-live qemu-user flakiness," \
			     " not a logic error here; retrying from a clean stage-1" \
			     " extraction, see the header) ==" >&2
			stage1
		fi
		# run_in_chroot_once, deliberately NOT run_in_chroot -- this
		# script's own generic retry wrapper repairs via `dpkg
		# --configure -a` and retries in place, which is unsafe here
		# specifically (see the header: debootstrap's --second-stage
		# writes its own dpkg status bootstrap stub unconditionally at
		# the top of the script, so an in-place rerun corrupts it
		# further, confirmed live). This loop's own clean-stage-1-
		# reextraction retry (above) is the only safe recovery for
		# this one step.
		if run_in_chroot_once /debootstrap/debootstrap --second-stage; then
			break
		fi
		attempt=$((attempt + 1))
		if [ "$attempt" -gt "$max_attempts" ]; then
			echo "stage 2 failed $max_attempts times in a row -- this is beyond" \
			     " the known qemu-user flakiness this script already tolerates;" \
			     " something else is wrong, see $rootdir/debootstrap/debootstrap.log" >&2
			exit 1
		fi
	done
	echo "$suite" > "$rootdir/etc/debian_chroot"
else
	echo "second stage already completed (found /etc/debian_chroot)"
fi

echo "== diverting systemd-tmpfiles to a no-op for the rest of package" \
     " installation =="
# Confirmed live, the hard way: seeding tmpfiles from the host (via
# seed_tmpfiles, defined above) BEFORE letting the guest retry does NOT
# stop `systemd-tmpfiles
# --create` from crashing proot again on the very next guest-side
# invocation -- re-verified live against an already-fully-seeded rootdir,
# same crash, same line, every time. So the earlier theory (it only
# crashes on the *create new* path, and pre-seeding avoids that) was
# wrong specifically for tmpfiles: it crashes unconditionally, regardless
# of whether there is anything left to do. seed_sysusers really does work
# this way for systemd-sysusers (confirmed separately, that one only
# crashes when actually creating something new) -- it's specifically
# systemd-tmpfiles that cannot be made to run safely under this proot
# build at all, ever, no matter the state.
#
# The only remaining fix is to make sure the GUEST never actually
# executes the real systemd-tmpfiles binary during package installation
# in the first place -- the same well-established technique container/
# rootfs-building pipelines already use for policy-rc.d (blocking service
# *starts* during package installs): divert the binary to a no-op stub
# for the whole remaining install, then run the real thing exactly once,
# for real, from the HOST (no qemu/proot at all) after every package is
# already installed, right before this script's final cleanup. Every
# package's own dh_installtmpfiles-generated postinst hook (not just
# systemd's own) becomes a harmless no-op this way, since it's the same
# one binary path they all call.
#
# dpkg-divert, not a plain overwrite: it works even though systemd
# (fully providing /usr/bin/systemd-tmpfiles) may not be installed yet at
# this exact point in the base system -- it only needs the package
# database entry to exist so that when systemd/systemd-tmpfiles DOES get
# unpacked moments later (as part of $base_packages below), dpkg
# redirects that unpack to the .real path instead of overwriting this
# stub, exactly as it would for any other file already on disk with a
# registered diversion.
run_in_chroot_once dpkg-divert --local --rename \
	--divert /usr/bin/systemd-tmpfiles.real --add /usr/bin/systemd-tmpfiles
mkdir -p "$rootdir/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "$rootdir/usr/bin/systemd-tmpfiles"
chmod 755 "$rootdir/usr/bin/systemd-tmpfiles"

echo "== apt sources (pinned to the snapshot, not the live archive) =="
mkdir -p "$rootdir/etc/apt/apt.conf.d"
cat > "$rootdir/etc/apt/sources.list" <<EOF
deb [check-valid-until=no] $mirror $suite main contrib non-free-firmware non-free
EOF
# Belt-and-suspenders alongside the inline check-valid-until=no above --
# some apt versions only honor the global knob for certain sub-fetches
# (e.g. Release.gpg itself).
cat > "$rootdir/etc/apt/apt.conf.d/99x716b-snapshot.conf" <<'EOF'
Acquire::Check-Valid-Until "false";
APT::Install-Recommends "false";
EOF

echo "== installing base packages (proper apt dependency resolution) =="
# Matches build-ubuntu-rootfs.sh's own hand-picked base list, Debian
# package names: NetworkManager/wpasupplicant (ath11k), bluez (hci_qca),
# this project's established debug toolset (buildroot/configs/
# x716_defconfig has the same list).
#
# alsa-ucm-conf: confirmed live, its absence is the actual root cause of
# a "sound is broken" report -- this device's card (Qualcomm sm8550,
# exposed as "Samsung-Galaxy-Tab-S9-5G") needs an ALSA UCM2 profile to
# expose real sinks/sources at all; this project's own overlay
# (rootfs/overlay-common/usr/share/alsa/ucm2/Qualcomm/sm8550/GTS9/*)
# ships that device-specific profile, but without the *stock* alsa-
# ucm-conf package's own shared ucm2 tree alongside it, WirePlumber's
# ALSA monitor can't fully resolve it and silently falls back to a fake
# "Dummy Output" sink with no real sinks/sources at all (confirmed live
# via `wpctl status`). Installing alsa-ucm-conf merges its stock tree
# into the same /usr/share/alsa/ucm2 directory our overlay already
# populated -- confirmed live, no file collisions with our own
# Qualcomm/sm8550/GTS9 files -- and after that, WirePlumber correctly
# exposes the real hardware ("Built-in Audio Built-in speakers (4x
# CS35L45)" / "Built-in digital microphones", matching this device's
# known hardware) with no further configuration needed. The same
# mechanism NixOS's hardware.nix handles via ALSA_CONFIG_UCM2 pointing
# at a package-time merge of the two trees (see nixos/packages/
# x716b-ucm.nix) -- Debian's FHS /usr/share/alsa/ucm2 already being the
# real, default, hardcoded search path (unlike NixOS's store-based
# layout) means no env var override is needed here at all, just the
# missing package.
base_packages="systemd-sysv sudo locales tzdata console-setup keyboard-configuration \
network-manager wpasupplicant bluez \
openssh-server \
e2fsprogs dosfstools parted \
iputils-ping curl wget ca-certificates \
nano less htop rsync unzip \
usbutils pciutils ethtool i2c-tools strace tree iw tcpdump \
chrony zram-tools alsa-utils alsa-ucm-conf device-tree-compiler kmod \
dbus python3"

run_in_chroot apt-get update
run_in_chroot apt-get install -y $base_packages

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

echo "== fstab (LABEL=X716B_ROOT -- shared with every other rootfs on this" \
     " port, see scripts/build-real-root-initramfs.sh's findfs lookup) =="
cat > "$rootdir/etc/fstab" <<'EOF'
LABEL=X716B_ROOT	/	ext4	defaults,noatime,errors=remount-ro	0 1
EOF

echo "== users =="
run_in_chroot bash -c "echo 'root:${username}' | chpasswd"
if ! grep -q "^$username:" "$rootdir/etc/passwd"; then
	run_in_chroot useradd -m -s /bin/bash \
		-G sudo,tty,audio,video,input,dialout,netdev "$username"
	run_in_chroot bash -c "echo '${username}:${username}' | chpasswd"
fi
# useradd -m's own chown of the new home directory to the new user does
# NOT reliably persist to the real on-disk ownership -- proot's -0
# fake-root chown is a ptrace-layer illusion for the REST OF THAT SAME
# proot session (later stat() calls inside it see the faked owner), but
# it is not guaranteed to be the real underlying chown(2) result once the
# session ends. Confirmed live: /home/x716b booted on real hardware still
# owned by root:root, blocking SSH login from chdir-ing into $HOME even
# though auth succeeded.
#
# A first attempt at fixing this tried a real chown(1) inside run_in_ns's
# wide-mapped namespace -- wrong, and confirmed live the hard way:
# run_in_ns's chown resolves ITS OWN numeric argument against the
# ACTIVE NAMESPACE mapping, not against any meaningful real identity.
# "chown 1000:1000" inside that namespace does NOT mean "real host uid/
# gid 1000" -- 1000 falls inside the wide subordinate range
# ("1:$subuid_base:65536"), so it resolved to real host uid/gid
# ~100999 instead (confirmed live via `stat`: "Uid: (100999/ UNKNOWN)").
# That's a DIFFERENT wrong owner on the real shipped image, not a fix.
# And there is no numeric target this unprivileged build can correctly
# make persist to real disk as exactly 1000:1000 in general: an
# unprivileged process can only make a real chown(2) stick for (a) its
# own real uid/gid, or (b) something in its own delegated /etc/subuid/
# /etc/subgid range -- 1000 is neither (this host's own real uid happens
# to also be 1000, pure coincidence, but its real *gid* is 100, not
# 1000, so even that only half-works).
#
# The actual fix: don't fight build-time uid mapping at all -- let the
# REAL DEVICE's own first real boot fix this for real, with genuine root
# and genuine NSS resolution against its own /etc/passwd (no numeric
# coincidence needed). systemd-tmpfiles' "z" line type adjusts an
# existing path's ownership/mode, resolving user/group by NAME at the
# time it runs -- shipped as a static config line, this applies
# correctly on every real boot via systemd-tmpfiles-setup.service,
# which runs early, well before sshd/getty accept any login.
mkdir -p "$rootdir/etc/tmpfiles.d"
echo "z /home/$username - $username $username - -" \
	> "$rootdir/etc/tmpfiles.d/x716b-home-owner.conf"

echo "== ssh =="
mkdir -p "$rootdir/etc/ssh/sshd_config.d"
cat > "$rootdir/etc/ssh/sshd_config.d/10-x716b.conf" <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

echo "== vendor firmware (WiFi/BT calibration + GPU + ADSP PIL/PDR/topology) =="
# Same allowlist/paths as build-fedora-rootfs.sh -- sid is merged-/usr,
# so /usr/lib/firmware is the one real location (no /lib vs /usr/lib
# split to worry about, unlike the compat symlink NixOS needed).
fwdir="$rootdir/usr/lib/firmware"
mkdir -p "$fwdir/qcom" "$fwdir/qca"
if [ -d "$repo_root/buildroot/firmware-overlay/lib/firmware" ]; then
	cp -a "$repo_root/buildroot/firmware-overlay/lib/firmware/." "$fwdir/"
else
	echo "    WARN: buildroot/firmware-overlay not built -- run scripts/fetch-ath11k-firmware.sh first" >&2
fi
vfw="$repo_root/vendor-firmware-dump/firmware"
for f in a740_zap.mdt a740_zap.b00 a740_zap.b01 a740_zap.b02 a740_sqe.fw gmu_gen70200.bin; do
	if [ -f "$vfw/$f" ]; then
		cp "$vfw/$f" "$fwdir/qcom/$f"
	else
		echo "    WARN: $vfw/$f not found -- GPU firmware will be incomplete" >&2
	fi
done

echo "== ADSP PIL firmware + HexagonFS payload + AudioReach topology =="
mkdir -p "$fwdir/qcom/sm8550"
adspfw="$repo_root/vendor-firmware-dump/firmware/qcom-sm8550"
if [ -d "$adspfw" ] && [ -n "$(ls -A "$adspfw" 2>/dev/null)" ]; then
	# Whole directory, not a glob -- missing any one of the four PDR
	# service-registry .jsn files here reproduces the exact "pd-mapper:
	# no pd maps available" failure diagnosed live during the NixOS
	# session (see docs/porting-log.md). This checkout doesn't currently
	# have them extracted at all -- a pre-existing gap shared by every
	# rootfs builder, not something to fix here; re-run
	# scripts/extract-vendor-firmware.sh against the device's own
	# partitions to close it for all of them at once.
	cp "$adspfw"/* "$fwdir/qcom/sm8550/"
else
	echo "    WARN: $adspfw empty -- ADSP will not probe and the sound card will not instantiate (re-run scripts/extract-vendor-firmware.sh)" >&2
fi
hexagonfs_root="$rootdir/usr/share/qcom/sm8550/Samsung/gts9-5g"
mkdir -p "$hexagonfs_root/dsp"
hexfw="$repo_root/vendor-firmware-dump/hexagonfs/dsp/adsp"
if [ -d "$hexfw" ]; then
	cp -a "$hexfw/." "$hexagonfs_root/dsp/"
else
	echo "    WARN: $hexfw not found -- sensor HexagonFS payload missing" >&2
fi

echo "== kernel module tree (must match the boot bundle's Image vermagic) =="
krel=$(cat "$repo_root/out/kernel/include/config/kernel.release" 2>/dev/null || true)
moddir="$repo_root/out/kernel/modules-out/lib/modules/$krel"
if [ -n "$krel" ] && [ -d "$moddir" ]; then
	mkdir -p "$rootdir/lib/modules"
	cp -a "$moddir" "$rootdir/lib/modules/$krel"
else
	echo "    WARN: $moddir not found -- run scripts/build-mainline-kernel.sh first" >&2
fi

echo "== device overlay (rootfs/overlay-common + rootfs/overlay-systemd," \
     " applied verbatim -- Debian is systemd + merged-/usr, same as" \
     " Fedora, so unlike NixOS this needs no translation at all) =="
cp -a "$repo_root/rootfs/overlay-common/." "$rootdir/"
cp -a "$repo_root/rootfs/overlay-systemd/." "$rootdir/"

echo "== fastrpc system user (hexagonrpcd units run as this, matching" \
     " build-fedora-rootfs.sh) =="
run_in_chroot groupadd -r fastrpc || true
run_in_chroot useradd -r -g fastrpc -s /usr/sbin/nologin -d / fastrpc || true

echo "== build deps for the source-built Qualcomm sensor/ADSP stack =="
# Debian names for build-fedora-rootfs.sh's own dnf build-dep list
# (meson ninja-build gcc git curl tar patch make pkgconf-pkg-config
# glib2-devel libgudev-devel systemd-devel polkit-devel kmod
# libqmi-devel protobuf-c-devel qrtr-devel xz-devel python3-devel
# python3-protobuf) -- confirm each resolves live against the pinned
# snapshot; `apt-cache search <lib>` inside the chroot is the next step
# for any that don't, not a re-guess ahead of time. liblzma-dev is here
# because pd-mapper's json.c #includes lzma.h directly (confirmed live
# during the NixOS port -- a real, non-obvious dependency dnf's package
# split didn't make obvious either).
run_in_chroot apt-get install -y \
	meson ninja-build build-essential git curl ca-certificates tar patch pkg-config \
	libglib2.0-dev libgudev-1.0-dev libudev-dev libsystemd-dev libpolkit-gobject-1-dev \
	libqmi-glib-dev libqrtr-glib-dev libqrtr-dev qrtr-tools \
	libprotobuf-c-dev protobuf-c-compiler protobuf-compiler \
	liblzma-dev python3-dev python3-protobuf gtk-doc-tools libumockdev-dev

echo "== pkg-config compat symlinks for old udev/systemd .pc names =="
# hexagonrpcd's and iio-sensor-proxy's meson.build files both do
# dependency('udev') / dependency('systemd') -- the OLD pkg-config names
# from when udev/systemd shipped as separate packages. Modern systemd
# (which now owns both) ships libudev-dev/libsystemd-dev with their
# pkg-config files named libudev.pc/libsystemd.pc instead, confirmed live
# (`dpkg -L`) -- Debian does not ship udev.pc/systemd.pc compatibility
# aliases the way some other distros' -devel-style packages still do.
# Symlinks are the standard, minimal fix (the same one Debian's own
# iio-sensor-proxy packaging carries as a patch, for the same reason).
# Placed here, before EVERY source build below (not just iio-sensor-
# proxy's) -- hexagonrpcd's own meson.build also calls
# dependency('systemd') to locate systemdsystemunitdir, and without this
# fix that call silently fell back to installing its .service files under
# /usr/lib/aarch64-linux-gnu/systemd/system instead of the real
# /usr/lib/systemd/system (confirmed live) rather than erroring the way
# iio-sensor-proxy's stricter meson.build does.
#
# aarch64-linux-gnu hardcoded, not looked up -- this whole script only
# ever targets one arch (arm64/aarch64), same assumption $arch already
# makes throughout.
ln -sf libudev.pc "$rootdir/usr/lib/aarch64-linux-gnu/pkgconfig/udev.pc"
ln -sf libsystemd.pc "$rootdir/usr/lib/aarch64-linux-gnu/pkgconfig/systemd.pc"

echo "== building libssc 0.4.4 (not packaged) =="
run_in_chroot bash -c '
	set -eu
	export HOME=/root
	d=$(mktemp -d)
	curl -sfL "https://codeberg.org/DylanVanAssche/libssc/archive/v0.4.4.tar.gz" \
		| tar xz -C "$d" --strip-components=1
	meson setup "$d/build" "$d" -Dprefix=/usr -Db_lto=true
	meson compile -C "$d/build"
	meson install --no-rebuild -C "$d/build"
'

echo "== building pd-mapper 1.1 (not packaged) =="
run_in_chroot bash -c '
	set -eu
	export HOME=/root
	d=$(mktemp -d)
	curl -sfL "https://github.com/andersson/pd-mapper/archive/refs/tags/v1.1.tar.gz" \
		| tar xz -C "$d" --strip-components=1
	make -C "$d" prefix=/usr
	make -C "$d" install prefix=/usr
'

echo "== building hexagonrpcd 0.4.0 with the Samsung patches =="
patches_host="$repo_root/specs/hexagonrpcd-samsung/patches"
mkdir -p "$rootdir/tmp/hexagonrpcd-patches"
cp "$patches_host"/*.patch "$patches_host/10-fastrpc.rules" "$rootdir/tmp/hexagonrpcd-patches/"
run_in_chroot bash -c '
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
	install -Dm644 /tmp/hexagonrpcd-patches/10-fastrpc.rules -t /usr/lib/udev/rules.d/
	# hexagonrpcds meson.build installs the .service units under
	# get_option(libdir)/systemd/system -- on Debian, libdir defaults to
	# the multiarch triplet dir, so that resolves to
	# /usr/lib/aarch64-linux-gnu/systemd/system, not the real systemd
	# search path (/usr/lib/systemd/system) -- confirmed live, systemctl
	# could not find these units at all after install. Relocate them;
	# simpler and more robust than fighting mesons install_dir logic for
	# one three-file case.
	mkdir -p /usr/lib/systemd/system
	mv /usr/lib/aarch64-linux-gnu/systemd/system/hexagonrpcd-*.service /usr/lib/systemd/system/
'

echo "== building iio-sensor-proxy 3.9 with libssc (SSC) support =="
mkdir -p "$rootdir/tmp/iio-sensor-proxy-patches"
cp "$repo_root/specs/iio-sensor-proxy-libssc/patches/notify-slow-sensor-discovery.patch" \
	"$rootdir/tmp/iio-sensor-proxy-patches/"
run_in_chroot bash -c '
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
rm -rf "$rootdir/tmp/hexagonrpcd-patches" "$rootdir/tmp/iio-sensor-proxy-patches"

echo "== chronyd sandboxing check =="
# NixOS's shipped chrony unit had CapabilityBoundingSet = "" (the empty
# *capability set*, i.e. deny everything -- NOT "no restriction", unlike
# RestrictAddressFamilies/SystemCallFilter's empty-means-unrestricted
# semantics) and failed to chown() /run/chrony even as root. Debian's
# chrony package ships its own systemd unit; if it carries the same
# directive, the fix is the same -- `~`, systemd's "full set" token, in
# an override, not a blanket strip. Not patched here pre-emptively
# because Debian's actual shipped unit hasn't been inspected yet --
# check `systemctl cat chrony` live at first boot (see the staged
# validation) and add /etc/systemd/system/chrony.service.d/override.conf
# with CapabilityBoundingSet=~ only if it's actually needed.

echo "== firewall: left off pending a kernel fragment addition =="
# The running kernel lacks CONFIG_NETFILTER_XT_MATCH_PKTTYPE -- confirmed
# live on NixOS, firewall.service failed outright ("Extension pkttype
# revision 0 not supported, missing kernel module?") rather than
# degrading. nftables/ufw aren't installed by the base_packages list
# above at all, so there's nothing to disable; if you add one later,
# expect the same failure until kernel/config/config-x716.fragment gains
# that symbol and the kernel is rebuilt.

echo "== serial console fallback on the USB gadget tty =="
# NOT systemd's serial-getty@.service template: it carries
# BindsTo=dev-%i.device, never satisfied for this gadget tty -- confirmed
# dead on Fedora *and* rediscovered independently on NixOS this port.
# Same standalone unit both of those carry, no device-unit dependency.
cat > "$rootdir/etc/systemd/system/x716b-serial-getty.service" <<'EOF'
[Unit]
Description=Serial getty on ttyGS0 (USB gadget console, no device-unit dependency)
Documentation=man:agetty(8)
After=multi-user.target

[Service]
ExecStart=-/sbin/agetty --keep-baud 115200 ttyGS0 $TERM
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

if [ "$desktop" = "kde" ]; then
	echo "== desktop: minimal Wayland Plasma (kde-plasma-desktop, not" \
	     " task-kde-desktop/kde-standard) =="
	# A deliberately narrower target than an earlier attempt at this
	# script's full tasksel selection (task-desktop + task-kde-desktop +
	# task-laptop with Install-Recommends=true) -- confirmed live that
	# pulled in ~1500 packages (full kde-standard, LibreOffice, GIMP,
	# accessibility/orca, print-manager, Akonadi/PIM data for KMail/
	# KOrganizer, ...) and took far too long to be worth it for what this
	# device actually needs: a working, minimal Plasma session.
	# kde-plasma-desktop is Debian's own minimal Plasma metapackage
	# (Depends: kde-baseapps, plasma-desktop, plasma-workspace, udisks2,
	# upower -- confirmed live via `apt-cache show`), a small fraction of
	# kde-standard's closure.
	#
	# Wayland is the DEPENDS-level default, not something extra to ask
	# for: plasma-workspace hard-Depends on kwin-wayland (confirmed live
	# via `apt-cache depends plasma-workspace`) regardless of Install-
	# Recommends, so a plain Depends-only install already gets a real
	# Wayland session (SDDM auto-detects /usr/share/wayland-sessions/ at
	# login) -- no -o APT::Install-Recommends=true needed or used here,
	# unlike the earlier attempt; this script's global Recommends=false
	# (see the apt.conf.d snippet above, kept for reproducibility) is
	# fine for this narrower target.
	#
	# sddm-theme-breeze IS explicitly needed, though: confirmed live via
	# `apt-cache depends sddm` that sddm itself has NO theme as a hard
	# Depends at all -- only as one of several Recommends alternatives.
	# This is the actual root cause of an earlier attempt's "SDDM greeter
	# process is running but the desktop is not functional": built with
	# the global Recommends=false, sddm installed with zero greeter theme
	# and nothing to actually render at the login screen. One explicit
	# package, not a blanket Recommends flip, fixes exactly that gap.
	#
	# bluedevil: the KDE Bluetooth system-tray applet/KCM (bluez itself
	# is already in base_packages) -- without it there is no user-facing
	# way to pair/manage Bluetooth devices from the desktop at all.
	# kde-config-tablet: the actual Debian package name for the Wacom
	# digitizer System Settings KCM (there is no "wacomtablet"/"plasma-
	# wacom"-named package here, confirmed live via apt-cache search --
	# this is the one that exists).
	# network-manager-tui: provides nmtui, NOT bundled into network-
	# manager itself on Debian (confirmed live) -- network-manager is
	# already in base_packages for the daemon/nmcli.
	#
	# xserver-xorg-input-libinput: confirmed live via `apt-cache depends
	# sddm`/`xserver-xorg-core`, neither hard-Depends nor Recommends an
	# actual input driver module -- the greeter's Xorg had no working
	# touchscreen at all (only xserver-xorg-input-wacom for the S Pen,
	# confirmed via `dpkg -l`; the touchscreen's own kernel input device,
	# `fts1ba90a`, registers correctly -- `/proc/bus/input/devices`
	# confirmed it has proper ABS/touch event bits -- it is purely an
	# Xorg-side driver gap). This only affects the SDDM *greeter*: the
	# real Plasma session, once logged in, is already Wayland (kwin-
	# wayland is plasma-workspace's own hard Depends, confirmed above) and
	# reads touch natively via libinput with no Xorg driver involved at
	# all. Tried switching the greeter itself to Wayland too
	# (DisplayServer=wayland in sddm.conf.d, which would make this
	# package moot for the greeter) -- confirmed live that SDDM's own
	# Wayland greeter support, marked "experimental" in its own example
	# config, genuinely fails to start on this hardware
	# (SDDM::Auth::HELPER_DISPLAYSERVER_ERROR, falling back to x11-user
	# automatically) even though kwin_wayland itself runs fine standalone
	# -- not pursued further per explicit user direction; X11-greeter +
	# Wayland-session is the accepted middle ground.
	#
	# plasma-keyboard: already pulled in transitively by kde-plasma-
	# desktop (confirmed live via `dpkg -l` before this was ever added
	# explicitly) -- listed anyway so the dependency is intentional and
	# documented, not incidental, matching the explicit ask. SDDM's own
	# InputMethod=qtvirtualkeyboard is already the schema default
	# (confirmed via `sddm --example-config`), so no extra sddm.conf.d
	# override is needed for the greeter to try showing it -- this
	# package is what makes that default actually have something to load.
	#
	# pipewire/pipewire-pulse/pipewire-alsa/wireplumber: confirmed live
	# neither pipewire nor pulseaudio was installed at all -- base_packages
	# above only ever had alsa-utils (raw ALSA CLI tools, no session/
	# routing daemon). wireplumber is pipewire's session/policy manager
	# (equivalent to what pulseaudio's own logic used to do) -- without
	# it pipewire has no policy engine and most apps won't find a working
	# audio sink. pipewire-pulse provides the PulseAudio-compatible socket
	# most apps (including Electron/Chromium-based ones) still expect.
	#
	# kscreen: NOT pulled in by kde-plasma-desktop's own minimal Depends
	# closure (confirmed live via `dpkg -l` -- only libkscreen-data, the
	# plain library, was present) -- without it there is no "Display
	# Configuration" page in System Settings at all, confirmed live (user
	# report: "display settings are missing in kde"). This is also the
	# *correct* way to set this device's display scale, confirmed live
	# the hard way: forcing QT_SCALE_FACTOR/GDK_SCALE via environment.d
	# for the real Wayland session conflicts with kwin_wayland's own
	# native per-output Wayland scale protocol -- Qt renders widgets at
	# the forced scale while the compositor reserves panel/dock screen
	# space using its own (different) scale, which is what caused a
	# live-confirmed clipped/cut-off taskbar. kscreen's own Display
	# Configuration KCM sets the real Wayland-native per-output scale
	# instead, which kwin_wayland and every client agree on through the
	# protocol itself -- no mismatch. Per explicit user direction, no
	# environment-variable-based scale forcing is shipped by this script
	# at all (for either the greeter or the session) -- set it live via
	# System Settings if and when you want it scaled.
	#
	# mesa-vulkan-drivers/libgl1-mesa-dri: real GPU-accelerated rendering
	# (freedreno), not a software fallback -- confirm their exact names
	# live against the pinned snapshot the same way every other "not
	# guessed ahead of time" package in this script is.
	run_in_chroot apt-get install -y \
		kde-plasma-desktop sddm sddm-theme-breeze \
		mesa-vulkan-drivers libgl1-mesa-dri \
		network-manager-tui bluedevil kde-config-tablet \
		xserver-xorg-input-libinput plasma-keyboard \
		pipewire pipewire-pulse pipewire-alsa wireplumber \
		kscreen
	run_in_chroot systemctl set-default graphical.target
	run_in_chroot systemctl enable sddm.service
fi

echo "== enabling services =="
for unit in \
	NetworkManager bluetooth chrony ssh \
	hexagonrpcd-adsp-rootpd \
	pd-mapper \
	gts9wifi-bt-provision \
	gts9wifi-wait-sensor-proxy \
	gts9wifi-panel-coldboot-recover \
	gts9wifi-grow-rootfs \
	gts9wifi-usb-net gts9wifi-wifi-recover gts9wifi-sensor-registry-perms \
	gts9wifi-x11-dir-fix.timer gts9wifi-audio-init \
	mnt-vendor-persist.mount vendor-dsp.mount vendor-firmware_mnt.mount
do
	run_in_chroot systemctl enable "$unit" >/dev/null 2>&1 \
		|| echo "    WARN: unit not found: $unit" >&2
done
# Matches the Fedora/gts9wifi-fedora preset's own deliberate exclusions:
# the ADSP chain (hexagonrpcd-adsp-sensorspd + gts9wifi-adsp-boot) is
# manual-start -- its start can SSR or freeze the SoC, and starting it
# concurrently with panel-coldboot-recover's pm_test suspend froze the
# board outright on real hardware. Start it by hand, one unit at a time.
# gts9wifi-bt-revive is also manual (run when hci0 disappears).

echo "== lifting the systemd-tmpfiles diversion and running it for real" \
     " (see the diversion setup above for why) =="
rm -f "$rootdir/usr/bin/systemd-tmpfiles"
run_in_chroot_once dpkg-divert --local --rename --remove /usr/bin/systemd-tmpfiles
seed_tmpfiles

echo "== cleaning =="
run_in_chroot apt-get clean
# No qemu-aarch64-static binary was ever copied into $rootdir -- proot
# invokes $QEMU_AARCH64_STATIC by its host path directly (see the header),
# nothing guest-side to clean up here.

# || true: du exits nonzero (under set -e, aborting the script right
# here with no further output) if it can't read every subdirectory --
# confirmed live, some content (e.g. sddm's /var/lib/sddm, systemd's
# /run/systemd/dissect-root) ends up owned by a mapped-namespace uid via
# run_in_ns's wide subuid/subgid range, unreadable to this script's own
# plain unprivileged invocation. The printed total is still informative
# even though incomplete; not worth blocking the build over.
du -sh "$rootdir" || true
echo "rootfs directory ready at $rootdir"
echo "next: tar it (matching x716b-fedora-*-rootfs.tar.gz's contract) or" \
     " build a raw ext4 image, label X716B_ROOT, and deploy with" \
     " scripts/deploy-rootfs.sh."
