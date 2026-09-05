#!/usr/bin/env bash
# Build a minimal debug-only initramfs for early bring-up: a static
# busybox + a /init that just proves userspace hand-off worked, then loops
# forever (never exits -- an init that exits panics the kernel). This is
# NOT the real Ubuntu rootfs (that's Phase 4) -- its only job is to give an
# unambiguous "the kernel reached userspace" signal for sec-log capture.
#
# Must run inside `nix-shell` (shell.nix), which exports
# BUSYBOX_AARCH64_STATIC pointing at a fully static aarch64 busybox (the
# default dynamically-linked one references a Nix store path as its ELF
# interpreter, which won't exist on-device).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ -z "${BUSYBOX_AARCH64_STATIC:-}" ]; then
	echo "BUSYBOX_AARCH64_STATIC not set -- run this inside nix-shell" >&2
	exit 1
fi

echo "== staging ramdisk contents =="
mkdir -p "$workdir"/{bin,sbin,proc,sys,dev,tmp}
cp "$BUSYBOX_AARCH64_STATIC" "$workdir/bin/busybox"

for applet in sh mount umount cat echo ls dmesg sleep switch_root sync mkdir; do
	ln -sf busybox "$workdir/bin/$applet"
done

cat > "$workdir/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

# Repurpose the vibrator (kernel/dts/sm8550-samsung-x716b.dts's gpio-leds
# node, GPIO 18) the instant userspace starts: a burst of 5 fast pulses,
# unmistakably different from the kernel's own steady "heartbeat" trigger
# pattern. Added 2026-09-05 to answer directly: the kernel-side heartbeat
# alone does NOT prove userspace/PID 1 is ever reached -- it would keep
# blinking even if the kernel got stuck forever in the deferred-probe/
# driver-matching mechanism (not a bug, not something hung_task or a
# panic would catch, just the kernel retrying by design). If this burst
# is ever felt, /init genuinely started running; if it's never felt, the
# plain kernel heartbeat continuing proves nothing about userspace.
for trig in /sys/class/leds/*/trigger; do
	echo none > "$trig" 2>/dev/null
done
i=0
while [ "$i" -lt 5 ]; do
	for b in /sys/class/leds/*/brightness; do
		echo 1 > "$b" 2>/dev/null
	done
	/bin/busybox sleep 1
	for b in /sys/class/leds/*/brightness; do
		echo 0 > "$b" 2>/dev/null
	done
	/bin/busybox sleep 1
	i=$((i + 1))
done
for trig in /sys/class/leds/*/trigger; do
	echo none > "$trig" 2>/dev/null
done

# USB Type-C bring-up probe check: now that userspace is confirmed reached,
# inspect /sys directly for which of the three new i2c chip drivers
# actually bound to a device, and vibrate the result -- far faster to
# iterate on than a kernel rebuild (this is a ramdisk-only change), and
# doesn't need USB itself to already work. Added 2026-09-05 after a full
# USB Type-C stack (ptn3222 eUSB2 repeater, ps5169 redriver, sm5714 TCPM)
# failed to enumerate on the host at all -- see docs/porting-log.md.
#
# Encoding: pulse count = (number of chips bound) + 1, i.e. 1 pulse means
# zero bound, 4 pulses means all three bound (avoids an ambiguous "zero
# pulses" case). Same 1s on/off rhythm as the userspace-reached burst, but
# distinguishable by count (always exactly 5 there, 1-4 here) and by the
# 3s pause separating this group from the burst before it and from the
# typec-port check after it.
pulse_n() {
	n=$1
	i=0
	while [ "$i" -lt "$n" ]; do
		for b in /sys/class/leds/*/brightness; do echo 1 > "$b" 2>/dev/null; done
		/bin/busybox sleep 1
		for b in /sys/class/leds/*/brightness; do echo 0 > "$b" 2>/dev/null; done
		/bin/busybox sleep 1
		i=$((i + 1))
	done
}

# $1 = bus (i2c or platform), $2 = driver name
is_bound() {
	dir="/sys/bus/$1/drivers/$2"
	[ -d "$dir" ] || return 1
	for e in "$dir"/*; do
		case "${e##*/}" in
			bind|unbind|module|uevent|new_device|delete_device|uevent_store) ;;
			*) return 0 ;;
		esac
	done
	return 1
}

# Attempt 22 result: 0/3 bound, 0 typec ports. Both i2c6/i2c12/i2c_hub_8/
# i2c_hub_9 already have default pinctrl states built into sm8550.dtsi
# (confirmed by reading it) -- board-level wiring shouldn't have been
# needed for the buses themselves to probe. This next check narrows
# whether the four bus *controllers* came up at all (adapter count) as
# distinct from whether our specific chips answered on them (client
# device count) -- "bus fine, chip never responded" (a power/regulator
# problem) vs. "bus itself never came up" (something more fundamental)
# point to very different next fixes.
#
# The original /sys/class/i2c-adapter/* glob was wrong -- that class only
# exists when CONFIG_I2C_CHARDEV registers /sys/class/i2c-dev/, not from
# the i2c core itself (confirmed by reading drivers/i2c/i2c-dev.c and
# drivers/i2c/i2c-core-base.c) -- and it was reporting 0 even once
# ptn3222 was confirmed bound, which is only possible if its adapter
# exists. The correct, config-independent path is the i2c bus itself:
# /sys/bus/i2c/devices/i2c-* (adapters are named "i2c-N"; client devices
# are named "<busnum>-<addr>", e.g. "6-004f", so this glob excludes them).
adapters=0
for a in /sys/bus/i2c/devices/i2c-*; do
	[ -e "$a" ] && adapters=$((adapters + 1))
done
/bin/busybox sleep 3
log "=== USB Type-C probe check: $adapters i2c adapter(s) present total -- vibrating $((adapters + 1)) pulses ==="
pulse_n $((adapters + 1))

# Attempt 25 result: real USB electrical attach started happening (host
# saw low-speed attach attempts, failing at descriptor read) after the
# QUP-wrapper fix, but the aggregate bound-count check still read 0 --
# not enough resolution to tell which (if any) of the three chips is the
# holdout. Checking each individually this time (2 pulses = bound, 1 =
# not) instead of one combined count.
for name in ptn3222 ps5169 sm5714-usbpd; do
	/bin/busybox sleep 3
	if is_bound i2c "$name"; then
		log "=== USB Type-C probe check: $name IS bound -- vibrating 2 pulses ==="
		pulse_n 2
	else
		log "=== USB Type-C probe check: $name NOT bound -- vibrating 1 pulse ==="
		pulse_n 1
	fi
done

# Attempt 28 result: forcing dr_mode="peripheral" produced ZERO change in
# the host-side USB symptom (identical low-speed misdetection/stall on
# every attempt before and after) -- ruling out OTG/role-switch as the
# cause. A fork investigation traced ptn3222's actual regulator/reset
# enable to its PHY framework .init callback, called from
# usb_1_hsphy's own driver (phy-qcom-snps-eusb2, platform driver name
# "snps-eusb2-hsphy") -- if THAT never binds, ptn3222's phy_init() never
# runs regardless of ptn3222 itself being fine. Checking platform-bus
# driver binding for both the HS PHY and the dwc3-qcom glue driver
# ("dwc3-qcom") for the first time here.
for name in snps-eusb2-hsphy dwc3-qcom; do
	/bin/busybox sleep 3
	if is_bound platform "$name"; then
		log "=== USB Type-C probe check: $name IS bound -- vibrating 2 pulses ==="
		pulse_n 2
	else
		log "=== USB Type-C probe check: $name NOT bound -- vibrating 1 pulse ==="
		pulse_n 1
	fi
done

/bin/busybox sleep 3
typec_ports=0
for p in /sys/class/typec/*; do
	[ -e "$p" ] && typec_ports=$((typec_ports + 1))
done
log "=== USB Type-C probe check: $typec_ports typec port(s) registered -- vibrating $((typec_ports + 1)) pulses ==="
pulse_n $((typec_ports + 1))

# Now forcing dr_mode="peripheral" on &usb_1 (kernel/dts/sm8550-samsung-x716b.dts)
# to bypass dwc3's OTG-hardware-readback-gated role-switch registration
# entirely (see that DTS comment for the full trace) -- ps5169/sm5714-usbpd
# staying unbound is now expected, not a problem to keep chasing. What
# actually matters now: does /dev/ttyGS0 appear at all. Check directly
# (separate from the background attach-loop above, which already does
# this for the shell itself) and report via vibration too, since we have
# no other way to know without host-side USB activity to go on.
/bin/busybox sleep 3
tries=0
ttygs0_found=0
while [ "$tries" -lt 10 ]; do
	if [ -c /dev/ttyGS0 ]; then
		ttygs0_found=1
		break
	fi
	/bin/busybox sleep 1
	tries=$((tries + 1))
done
log "=== USB Type-C probe check: /dev/ttyGS0 present=$ttygs0_found after ${tries}s -- vibrating $((ttygs0_found + 1)) pulses ==="
pulse_n $((ttygs0_found + 1))

# Attempt 30 result: snps-eusb2-hsphy/dwc3-qcom still unbound even with
# CONFIG_PHY_SNPS_EUSB2 fixed, but no structural bug found in either
# probe() on close reading -- both plausibly just mid deferred-probe
# retry (dwc3-qcom legitimately -EPROBE_DEFERs waiting on
# snps-eusb2-hsphy; that in turn should get retried once ptn3222, which
# IS bound, triggers driver_deferred_probe_trigger()). Rechecking
# everything again after a much longer wait to distinguish "still
# resolving" from "permanently stuck" -- our earlier checks all ran
# within the first ~30s of boot, plausibly too early.
#
# Attempt 31 result: this 30s recheck showed snps-eusb2-hsphy WAS
# resolved by then (confirming it was just a slow deferred-probe retry,
# not a real bug) -- but dwc3-qcom was still unbound even with its own
# phy dependency now available. Extended to 90s to see whether dwc3-qcom
# (and the things downstream of it -- ps5169/sm5714-usbpd/ttyGS0, which
# all could cascade-resolve once dwc3-qcom itself binds and registers
# usb_1's role-switch device) just needed even more patience.
/bin/busybox sleep 90
for name in snps-eusb2-hsphy dwc3-qcom; do
	if is_bound platform "$name"; then
		log "=== USB Type-C RECHECK (30s later): $name IS bound -- vibrating 2 pulses ==="
		pulse_n 2
	else
		log "=== USB Type-C RECHECK (30s later): $name NOT bound -- vibrating 1 pulse ==="
		pulse_n 1
	fi
	/bin/busybox sleep 2
done
for name in ps5169 sm5714-usbpd; do
	if is_bound i2c "$name"; then
		log "=== USB Type-C RECHECK (30s later): $name IS bound -- vibrating 2 pulses ==="
		pulse_n 2
	else
		log "=== USB Type-C RECHECK (30s later): $name NOT bound -- vibrating 1 pulse ==="
		pulse_n 1
	fi
	/bin/busybox sleep 2
done
ttygs0_found2=0
[ -c /dev/ttyGS0 ] && ttygs0_found2=1
log "=== USB Type-C RECHECK (30s later): /dev/ttyGS0 present=$ttygs0_found2 -- vibrating $((ttygs0_found2 + 1)) pulses ==="
pulse_n $((ttygs0_found2 + 1))

for trig in /sys/class/leds/*/trigger; do
	echo heartbeat > "$trig" 2>/dev/null
done

# Plain `echo` depends on /dev/console, which ABL's injected "console=null"
# cmdline arg makes unreliable (unclear whether it even resolves to a valid
# device, or silently discards). /dev/kmsg is a direct write into the
# kernel's own printk ring buffer -- delivered to every *registered*
# console (our sec-log driver included) regardless of which one "console="
# nominates as preferred, so it isn't subject to that same failure mode.
log() {
	echo "$1" > /dev/kmsg 2>/dev/null
	echo "$1"
}

log "=== linux-tabs9-port bring-up ramdisk: userspace reached ==="
log "=== /init running as PID $$, looping forever (this is not a crash) ==="

# USB gadget serial console (kernel/dts/sm8550-samsung-x716b.dts's minimal
# &usb_1/&usb_1_hsphy nodes + CONFIG_USB_G_SERIAL=y): if the gadget binds,
# /dev/ttyGS0 appears on its own -- no action needed here beyond waiting
# for it and attaching a shell. Runs as a background loop (not `exec`, and
# not the sole job) so /init itself never exits even if a shell session
# does (e.g. on USB replug) -- an exiting PID 1 panics the kernel.
(
	tries=0
	while [ "$tries" -lt 30 ]; do
		if [ -c /dev/ttyGS0 ]; then
			log "=== /dev/ttyGS0 present after ${tries}s, attaching shell ==="
			while true; do
				/bin/busybox sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1
				log "=== ttyGS0 shell session ended, respawning ==="
			done
		fi
		/bin/busybox sleep 1
		tries=$((tries + 1))
	done
	log "=== /dev/ttyGS0 never appeared after ${tries}s, giving up ==="
) &

# Persistent logging to the already-inserted, already-exFAT microSD card
# (kernel/dts/sm8550-samsung-x716b.dts's &sdhc_2). The sec-log/last_kmsg
# ring buffer is shared with ABL/XBL's own verbose preamble text and is too
# small (2 MiB) to survive the reboot-to-TWRP transition needed just to
# read it back -- late-boot/userspace evidence gets overwritten every time.
# A file on the SD card persists across any number of subsequent reboots.
# New filename each boot (uptime-independent, just a fixed name is fine
# since this is a debug-only ramdisk, not the real rootfs) -- overwritten
# on write, not appended, so it always reflects this boot's latest state.
SD_MNT=/mnt/sd
/bin/busybox mkdir -p "$SD_MNT"
SD_DEV=""
for dev in /dev/mmcblk1p1 /dev/mmcblk1 /dev/mmcblk0p1 /dev/mmcblk0; do
	[ -b "$dev" ] || continue
	if /bin/busybox mount -t exfat "$dev" "$SD_MNT" 2>/dev/null \
			|| /bin/busybox mount -t vfat "$dev" "$SD_MNT" 2>/dev/null; then
		SD_DEV=$dev
		break
	fi
done
if [ -n "$SD_DEV" ]; then
	log "=== microSD mounted from $SD_DEV at $SD_MNT ==="
	/bin/busybox dmesg > "$SD_MNT/x716-bringup-dmesg.txt" 2>&1
	/bin/busybox sync
else
	log "=== microSD mount FAILED (tried mmcblk1p1/mmcblk1/mmcblk0p1/mmcblk0) ==="
fi

i=0
while true; do
	/bin/busybox sleep 30
	i=$((i + 1))
	log "=== bring-up ramdisk heartbeat #$i (still alive, not hung) ==="
	if [ -n "$SD_DEV" ]; then
		/bin/busybox dmesg > "$SD_MNT/x716-bringup-dmesg.txt" 2>&1
		/bin/busybox sync
	fi
done
EOF
chmod +x "$workdir/init"

mkdir -p "$outdir"
out="$outdir/bringup-ramdisk.cpio.gz"

echo "== building $out =="
( cd "$workdir" && find . | cpio -o -H newc ) | gzip -9 > "$out"

ls -la "$out"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
