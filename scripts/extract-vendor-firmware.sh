#!/usr/bin/env bash
# Pull this device's own real, proprietary firmware/calibration blobs off
# its stock Android /vendor partition, via TWRP, into vendor-firmware-dump/.
#
# vendor-firmware-dump/ itself is committed to this repo (explicit user
# decision, Networking bring-up session, 2026-09-07 -- see
# docs/porting-log.md) so the build is reproducible without a device pull;
# it used to be gitignored as "proprietary, never commit" -- that caveat
# still applies to who owns this content (Samsung/Qualcomm's own binaries,
# not this project's), it's just no longer a reason to exclude it from git.
# This script remains useful for re-pulling from a fresh device/partition
# layout, or verifying the committed dump still matches real hardware.
#
# Written after doing this same extraction ad-hoc twice already this
# project (Session 6, touchscreen `tsp_stm/*`; Session 8, WiFi/BT
# `qca6490/*` + `hp*` files) -- codifies both so it doesn't need
# re-deriving by hand a third time.
#
# ## Why /vendor needs an explicit mount
#
# TWRP does *not* always auto-mount /vendor. When it hasn't, `/vendor`
# exists but is basically empty (`/vendor/firmware_mnt/image` shows only
# two sparse subdirs, no `/vendor/firmware` at all -- confirmed live,
# Networking bring-up session). The real partition is `dm-5`
# (`/dev/block/bootdevice/by-name/vendor` symlink target), ext4 (*not*
# erofs as the stock generic fstab entry suggests -- confirmed live).
# This script mounts it explicitly and idempotently before pulling
# anything.
#
# ## Usage
#
#   adb devices -l        # confirm the device shows up in `recovery` mode
#   bash scripts/extract-vendor-firmware.sh
#
# Re-running is safe: existing local files are left alone (adb pull
# overwrites, but the file sets pulled here don't change device to device
# unless firmware is genuinely updated).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir="$repo_root/vendor-firmware-dump"

echo "== checking device is reachable in TWRP =="
state=$(adb get-state 2>&1 || true)
if [ "$state" != "recovery" ]; then
	echo "error: device not in TWRP recovery (adb get-state says '$state')." >&2
	echo "Boot to TWRP first (adb reboot recovery from a booted Android system," >&2
	echo "or the recovery button combo from a powered-off state)." >&2
	exit 1
fi

echo "== mounting /vendor (dm-5, ext4) if not already mounted =="
if ! adb shell "grep -q ' /vendor ' /proc/mounts"; then
	adb shell "mount -t ext4 /dev/block/dm-5 /vendor"
fi
adb shell "ls /vendor/firmware >/dev/null" || {
	echo "error: /vendor/firmware still not present after mounting -- partition" >&2
	echo "layout may have changed; re-check with 'adb shell ls -la /dev/block/bootdevice/by-name/ | grep vendor'." >&2
	exit 1
}

# <local subdir under vendor-firmware-dump/> <remote path under /vendor>
pull_list=(
	"firmware/qca6490		/vendor/firmware/qca6490"
	"firmware/tsp_stm		/vendor/firmware/tsp_stm"
	"firmware/keyboard_stm		/vendor/firmware/keyboard_stm"
	"firmware/abov			/vendor/firmware/abov"
	"firmware/mfc			/vendor/firmware/mfc"
)
# Individual files (BT rampatch/NVM -- real, on-device "hp"-prefixed set;
# see kernel/dts/sm8550-samsung-x716b.dts's bluetooth node comment and
# docs/porting-log.md's Networking bring-up Session 8 entry for why these
# specific files, not "ht"-prefixed ones, are what mainline's hci_qca
# actually needs for this chip).
file_list=(
	/vendor/firmware/hpbtfw21.tlv
	/vendor/firmware/hpnv21.bin
	/vendor/firmware/hpnv21.b9a
	/vendor/firmware/hpnv21.b9b
	/vendor/firmware/hpnv21.baa
	/vendor/firmware/hpnv21.bb7
	/vendor/firmware/hpnv21.bb9
	/vendor/firmware/hpnv21g.bin
	/vendor/firmware/hpnv21g.b9a
	/vendor/firmware/hpnv21g.b9b
	/vendor/firmware/hpnv21g.baa
	/vendor/firmware/hpnv21g.bb7
	/vendor/firmware/hpnv21g.bb9
	/vendor/firmware/bt_nvm_loading.xml
	/vendor/firmware/bt_nvm_loading_2nd.xml
	/vendor/firmware/regdb.bin
)

echo "== pulling directories =="
# `adb pull <remote_dir> <dest>` creates <dest>/$(basename remote_dir)/...
# itself, so pull into local_sub's *parent* -- pulling into local_sub
# directly (after mkdir -p'ing it) would double the nesting, e.g.
# firmware/qca6490/qca6490/*.
while IFS= read -r line; do
	[ -z "$line" ] && continue
	local_sub=$(awk '{print $1}' <<<"$line")
	remote=$(awk '{print $2}' <<<"$line")
	parent_dir="$outdir/$(dirname "$local_sub")"
	mkdir -p "$parent_dir"
	echo "-- $remote --"
	adb pull "$remote" "$parent_dir/" 2>&1 | tail -3 || \
		echo "warning: $remote not found on this device -- skipping" >&2
done <<<"$(printf '%s\n' "${pull_list[@]}")"

echo "== pulling individual files =="
mkdir -p "$outdir/firmware"
for remote in "${file_list[@]}"; do
	f=$(basename "$remote")
	if adb shell "[ -f $remote ]" 2>/dev/null; then
		adb pull "$remote" "$outdir/firmware/$f" >/dev/null
		echo "pulled $f"
	else
		echo "not present on this device: $remote (skipping)"
	fi
done

echo "== done -- staged under $outdir (gitignored, proprietary) =="
find "$outdir" -type f | sort
