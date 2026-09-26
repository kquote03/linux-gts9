#!/usr/bin/env bash
# Build a minimal initramfs whose only job is to find the real root
# filesystem (the Alpine rootfs on the microSD card) and switch_root into
# it. Storage bring-up session, Phase E -- modeled directly on
# scripts/build-bringup-ramdisk.sh's structure (same static-busybox
# approach, same log()/retry-loop idioms), but with a genuine mount +
# switch_root instead of that script's "loop forever" placeholder.
#
# Why a real initramfs does the mount, rather than relying on the kernel's
# own root=/rootwait cmdline handling: mmc/UFS device enumeration is
# asynchronous (confirmed this session -- both took real, variable time to
# probe on this board), and a bounded retry loop here is simpler and more
# debuggable over the USB serial console than tuning rootwait/rootdelay
# blindly. The scripts/build-android-v4-bundle.sh cmdline's root=/rootfstype=
# (added this same session) are for documentation/tooling consistency, not
# actually consumed by the kernel's own root-mount code -- this script's
# /init is what really does it.
#
# Must run inside `nix-shell` (shell.nix), same BUSYBOX_AARCH64_STATIC
# requirement as build-bringup-ramdisk.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ -z "${BUSYBOX_AARCH64_STATIC:-}" ]; then
	echo "BUSYBOX_AARCH64_STATIC not set -- run this inside nix-shell" >&2
	exit 1
fi

# The real root is found by FILESYSTEM LABEL first (X716B_ROOT), so one
# initramfs serves every deploy target -- the microSD partition and the
# NixOS-on-userdata image both just carry that label (see nixos/). The
# device-node list is the fallback for the older Fedora microSD, whose
# root partition may be unlabelled: mmc block index isn't stable across
# boots (confirmed live -- the SD card has come up as both mmcblk0 and
# mmcblk1), so try both.
REAL_ROOT_LABEL=${REAL_ROOT_LABEL:-X716B_ROOT}
REAL_ROOT_CANDIDATES=${REAL_ROOT_CANDIDATES:-"/dev/mmcblk1p1 /dev/mmcblk0p1"}
REAL_ROOT_FSTYPE=${REAL_ROOT_FSTYPE:-ext4}

echo "== staging real-root initramfs contents =="
mkdir -p "$workdir"/{bin,sbin,proc,sys,dev,tmp,mnt/newroot}
cp "$BUSYBOX_AARCH64_STATIC" "$workdir/bin/busybox"

# WiFi/BT/GPU firmware, embedded directly in the initramfs -- NOT just
# staged in the real rootfs's own /usr/lib/firmware. Confirmed live
# (gts9wifi-fedora pivot, Session 9, real dmesg timestamps): ath11k and
# the Adreno GPU driver are both built-in (not modular, matching this
# project's own established philosophy) and request their firmware
# during their own early PCI/platform probe -- which happens *before*
# this initramfs's own /init has found and mounted the real root
# filesystem below (firmware load attempted at dmesg timestamp
# [1.294542], real root not mounted until [1.326643] -- a genuine ~32ms
# boot-order race, not a placement bug in the real rootfs). Copying the
# same already-proven firmware files here, available immediately, is a
# smaller, more surgical fix than converting these drivers to loadable
# modules (gts9wifi-fedora's own approach, which sidesteps the same race
# by deferring their probe until after switch_root instead).
fwdir="$workdir/lib/firmware"
repo_root_for_fw=$(cd "$repo_root" && pwd)
mkdir -p "$fwdir"
if [ -d "$repo_root_for_fw/buildroot/firmware-overlay/lib/firmware" ]; then
	cp -a "$repo_root_for_fw/buildroot/firmware-overlay/lib/firmware/." "$fwdir/"
else
	echo "Missing device firmware overlay; refusing an incomplete initramfs" >&2
	exit 1
fi
python3 "$repo_root/scripts/verify-wifi-firmware.py" --firmware-dir "$fwdir"
mkdir -p "$fwdir/qcom"
vfw="$repo_root_for_fw/vendor-firmware-dump/firmware"
for f in a740_zap.mdt a740_zap.b00 a740_zap.b01 a740_zap.b02 a740_sqe.fw gmu_gen70200.bin; do
	if [ -f "$vfw/$f" ]; then
		cp "$vfw/$f" "$fwdir/qcom/$f"
	else
		echo "WARNING: $vfw/$f not found -- GPU firmware will be incomplete" >&2
	fi
done

for applet in sh mount umount cat echo ls dmesg sleep switch_root sync mkdir \
	      findfs blkid grep ps cat ip ifconfig telnetd top df free lsmod kill killall \
	      tail head hexdump od; do
	ln -sf busybox "$workdir/bin/$applet"
done

# The charging screen reads the power/volume keys through /dev/input/event*, and
# evdev is a loadable module in this kernel (on the real system udev loads it
# from the rootfs).  There is no modprobe here, so carry the module and insmod it.
mkdir -p "$workdir/lib/modules"
evdev_zst=$(ls "$repo_root"/out/kernel/modules-out/lib/modules/*/kernel/drivers/input/evdev.ko.zst 2>/dev/null | head -1 || true)
if [ -n "$evdev_zst" ]; then
	zstd -dc "$evdev_zst" > "$workdir/lib/modules/evdev.ko"
else
	echo "NOTE: evdev.ko not found (fine only if CONFIG_INPUT_EVDEV=y)" >&2
fi

# Off-mode charging screen (rootfs/initramfs/gts9-charger.c), run by /init below
# when the tablet was started by a charger rather than the power key.
if [ -z "${MUSL_AARCH64:-}" ] || [ -z "${MUSL_AARCH64_DEV:-}" ]; then
	echo "MUSL_AARCH64 not set -- run this inside nix-shell" >&2
	exit 1
fi
echo "== building gts9-charger =="
clang --target=aarch64-unknown-linux-musl -static -Os -Wall -Wextra -nostdlib \
	-fuse-ld=lld -isystem "$MUSL_AARCH64_DEV/include" \
	-o "$workdir/bin/gts9-charger" "$repo_root/rootfs/initramfs/gts9-charger.c" \
	"$MUSL_AARCH64/lib/crt1.o" "$MUSL_AARCH64/lib/crti.o" \
	-L"$MUSL_AARCH64/lib" -lc "$MUSL_AARCH64/lib/crtn.o"

cat > "$workdir/init" <<EOF
#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

log() {
	echo "\$1" > /dev/kmsg 2>/dev/null
	echo "\$1"
}

log "=== linux-tabs9-port real-root initramfs: userspace reached ==="

# Debug network (opt-in, gts9.debugnet=1 on the command line): bring up the
# kernel USB gadget network and offer an unauthenticated root shell on it, so a
# stuck boot can be examined from the host (172.16.42.1).  Never enabled by
# default -- it is a root shell for anyone on the USB link.
case " \$(/bin/busybox cat /proc/cmdline) " in
*" gts9.debugnet=1 "*)
	/bin/busybox mkdir -p /dev/pts
	/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null
	(
		n=0
		while [ ! -e /sys/class/net/usb0 ] && [ "\$n" -lt 90 ]; do
			/bin/busybox sleep 1
			n=\$((n + 1))
		done
		/bin/busybox ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up
		/bin/busybox telnetd -l /bin/sh -b 172.16.42.1
		log "=== debugnet: telnet 172.16.42.1 (usb0 after \${n}s) ==="
	) &
	;;
esac

# Off-mode charging.  Samsung's ABL boots this same image when the tablet is
# started by plugging in a charger; it marks that boot on the command line the
# way it does for its own Android charger mode (androidboot.mode=charger, and
# the lpcharge=1 parameters of the Samsung modules).  gts9.charger=1 forces the
# charging screen and gts9.charger=0 disables it, for testing.  The charging
# screen returns when the user holds the power key; the boot then continues
# normally.  If it cannot run (no framebuffer, ...) it returns at once, so a
# broken charging screen never keeps the tablet from starting.
charger_mode=0
case " \$(/bin/busybox cat /proc/cmdline) " in
*" androidboot.mode=charger "*|*" androidboot.bootmode=charger "*|*lpcharge=1" "*)
	charger_mode=1 ;;
esac
case " \$(/bin/busybox cat /proc/cmdline) " in
*" gts9.charger=1 "*) charger_mode=1 ;;
*" gts9.charger=0 "*) charger_mode=0 ;;
esac

# Off-mode charging screen.  Runs BEFORE the real root is looked for: the gauge
# must never depend on the SD card (it may come up late, or not at all, in a
# charger boot).  A background job saves the app log and the kernel log to the
# SD card once it appears, so a hang leaves a trail (var/log/gts9-charger*.log).
if [ "\$charger_mode" = 1 ]; then
	log "=== charger boot: showing the charging screen ==="
	CLOG=/tmp/gts9-charger.log
	echo "--- charger boot \$(/bin/busybox cat /proc/uptime) ---" > \$CLOG
	# Console messages would be drawn over the gauge (console=tty0): mute them
	# for the duration, keeping the old levels to restore afterwards.
	old_printk=\$(/bin/busybox cat /proc/sys/kernel/printk)
	echo "1 1 1 1" > /proc/sys/kernel/printk
	echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null
	# Unbind the framebuffer console for the whole session: on every unblank it
	# repaints its text buffer over the framebuffer, wiping the gauge.
	fbcon_vt=""
	for v in /sys/class/vtconsole/vtcon*; do
		if /bin/busybox grep -q "frame buffer" \$v/name 2>/dev/null; then
			fbcon_vt=\$v
			echo 0 > \$v/bind
		fi
	done
	if [ -e /lib/modules/evdev.ko ] && [ ! -e /dev/input/event0 ]; then
		/bin/busybox insmod /lib/modules/evdev.ko
	fi
	(
		n=0; dev=""
		while [ -z "\$dev" ] && [ "\$n" -lt 120 ]; do
			cand=\$(/bin/busybox findfs "LABEL=$REAL_ROOT_LABEL" 2>/dev/null)
			if [ -n "\$cand" ] && [ -b "\$cand" ]; then dev=\$cand; break; fi
			for c in $REAL_ROOT_CANDIDATES; do
				if [ -b "\$c" ]; then dev=\$c; break; fi
			done
			[ -n "\$dev" ] && break
			/bin/busybox sleep 1
			n=\$((n + 1))
		done
		[ -n "\$dev" ] || exit 0
		/bin/busybox mkdir -p /mnt/logroot
		/bin/busybox mount -t $REAL_ROOT_FSTYPE -o rw "\$dev" /mnt/logroot || exit 0
		/bin/busybox mkdir -p /mnt/logroot/var/log
		echo "root \$dev found after \${n}s" >> \$CLOG
		while :; do
			/bin/busybox cat \$CLOG > /mnt/logroot/var/log/gts9-charger.log
			/bin/busybox dmesg > /mnt/logroot/var/log/gts9-charger-dmesg.log 2>/dev/null
			/bin/busybox sync
			/bin/busybox sleep 2
		done
	) &
	keeper=\$!
	n=0
	while [ ! -e /dev/fb0 ] && [ "\$n" -lt 15 ]; do
		/bin/busybox sleep 1
		n=\$((n + 1))
	done
	echo "fb0 after \${n}s" >> \$CLOG
	# The ANA38407 panel is unreachable after Samsung's cold-boot hand-off until
	# one platform-level suspend/resume cycle (see
	# rootfs/overlay-common/usr/libexec/gts9wifi-panel-coldboot-recover).
	if [ -w /sys/power/pm_test ] && [ -w /sys/power/state ] &&
	   /bin/busybox grep -qw platform /sys/power/pm_test; then
		echo "platform suspend cycle" >> \$CLOG
		echo platform > /sys/power/pm_test
		echo mem > /sys/power/state
		echo none > /sys/power/pm_test
		echo "platform suspend cycle done" >> \$CLOG
	fi
	/bin/gts9-charger \$CLOG
	rc=\$?
	echo "gts9-charger exited \$rc" >> \$CLOG
	kill \$keeper 2>/dev/null
	/bin/busybox sleep 1
	if [ -d /mnt/logroot/var/log ]; then
		/bin/busybox cat \$CLOG > /mnt/logroot/var/log/gts9-charger.log
		/bin/busybox sync
		/bin/busybox umount /mnt/logroot 2>/dev/null
	fi
	[ -n "\$fbcon_vt" ] && echo 1 > \$fbcon_vt/bind
	echo "\$old_printk" > /proc/sys/kernel/printk
	log "=== charging screen finished (\$rc): continuing the boot ==="
fi

REAL_ROOT_LABEL="$REAL_ROOT_LABEL"
REAL_ROOT_CANDIDATES="$REAL_ROOT_CANDIDATES"
REAL_ROOT_FSTYPE="$REAL_ROOT_FSTYPE"

# Bounded retry loop (mirrors the bring-up ramdisk's ttyGS0-wait pattern):
# mmc/UFS enumeration is asynchronous, confirmed this session to take a
# real, variable amount of time on this board. Each second: first ask for
# the labelled filesystem (works for any deploy target), then fall back to
# the fixed device-node list -- mmc block naming isn't stable across boots.
REAL_ROOT_DEV=""
tries=0
while [ "\$tries" -lt 30 ]; do
	if [ -n "\$REAL_ROOT_LABEL" ]; then
		cand=\$(/bin/busybox findfs "LABEL=\$REAL_ROOT_LABEL" 2>/dev/null)
		if [ -n "\$cand" ] && [ -b "\$cand" ]; then
			REAL_ROOT_DEV="\$cand"
			break
		fi
	fi
	for dev in \$REAL_ROOT_CANDIDATES; do
		if [ -b "\$dev" ]; then
			REAL_ROOT_DEV="\$dev"
			break 2
		fi
	done
	/bin/busybox sleep 1
	tries=\$((tries + 1))
done

if [ -z "\$REAL_ROOT_DEV" ]; then
	log "=== none of [\$REAL_ROOT_CANDIDATES] appeared after \${tries}s -- cannot continue ==="
	log "=== dropping to an emergency shell on ttyGS0 instead of switch_root ==="
	while true; do
		/bin/busybox sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1
	done
fi
log "=== \$REAL_ROOT_DEV present after \${tries}s ==="

if ! /bin/busybox mount -t "\$REAL_ROOT_FSTYPE" -o rw "\$REAL_ROOT_DEV" /mnt/newroot; then
	log "=== mount of \$REAL_ROOT_DEV (\$REAL_ROOT_FSTYPE) FAILED -- emergency shell ==="
	while true; do
		/bin/busybox sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1
	done
fi

log "=== real root mounted, switch_root-ing into it ==="
# Keep every boot's command line (the ABL-added part differs between a
# power-key boot and a charger-triggered one), plus whether the charging
# screen ran, so charger-boot detection can be checked against real boots.
/bin/busybox mkdir -p /mnt/newroot/var/log
echo "charger_mode=\$charger_mode \$(/bin/busybox cat /proc/cmdline)" \
	>> /mnt/newroot/var/log/gts9-boot-cmdlines.log 2>/dev/null
/bin/busybox killall telnetd 2>/dev/null
/bin/busybox umount /dev/pts 2>/dev/null
/bin/busybox mkdir -p /mnt/newroot/proc /mnt/newroot/sys /mnt/newroot/dev
/bin/busybox mount --move /proc /mnt/newroot/proc
/bin/busybox mount --move /sys /mnt/newroot/sys
/bin/busybox mount --move /dev /mnt/newroot/dev

exec /bin/busybox switch_root /mnt/newroot /sbin/init
EOF
chmod +x "$workdir/init"

mkdir -p "$outdir"
out="$outdir/real-root-initramfs.cpio.gz"

echo "== building $out =="
( cd "$workdir" && find . | cpio -o -H newc ) | gzip -9 > "$out"

ls -la "$out"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
