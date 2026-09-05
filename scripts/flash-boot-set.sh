#!/usr/bin/env bash
# Flash one or more boot-chain partitions to the physical tablet via
# `adb shell dd`, with size verification and a post-write readback+hash
# check. This is the only script in this repo that writes to the device.
#
# Per docs/boot-strategy.md's pre-flash checklist (no exceptions): before
# running this, confirm the tablet is in TWRP, take/verify a fresh nandroid
# backup of every partition being touched, and get explicit user
# confirmation naming the exact partition(s) and rollback plan. This script
# refuses to run without an explicit acknowledgement flag for exactly that
# reason -- it is not a substitute for that conversation, just a guard
# against running it by accident.
#
# Usage: flash-boot-set.sh --i-understand-this-writes-to-the-device \
#          boot=out/android/boot.img init_boot=out/android/init_boot.img ...
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

declare -A partition_sizes=(
	[boot]=100663296
	[init_boot]=8388608
	[vendor_boot]=100663296
	[dtbo]=16777216
)

if [ "${1:-}" != "--i-understand-this-writes-to-the-device" ]; then
	cat >&2 <<'EOF'
Refusing to run: this writes directly to physical device partitions.

Before running this script:
  1. Confirm the tablet is in TWRP: `adb devices` shows it in recovery mode.
  2. Take/verify a fresh nandroid backup of every partition listed below.
  3. Get explicit confirmation from whoever is directing this session,
     naming these exact partitions and the rollback plan.

Usage:
  flash-boot-set.sh --i-understand-this-writes-to-the-device \
    boot=path/to/boot.img init_boot=path/to/init_boot.img ...

Valid partition names: boot, init_boot, vendor_boot, dtbo
EOF
	exit 1
fi
shift

if [ "$#" -eq 0 ]; then
	echo "no partition=image pairs given" >&2
	exit 1
fi

if ! adb get-state 2>/dev/null | grep -q recovery; then
	echo "device is not in recovery (TWRP) mode -- aborting" >&2
	exit 1
fi

for pair in "$@"; do
	partition=${pair%%=*}
	image=${pair#*=}

	if [ -z "${partition_sizes[$partition]:-}" ]; then
		echo "unknown partition: $partition (valid: ${!partition_sizes[*]})" >&2
		exit 1
	fi
	if [ ! -f "$image" ]; then
		echo "image not found: $image" >&2
		exit 1
	fi

	expected_size=${partition_sizes[$partition]}
	actual_size=$(stat -c%s "$image")
	if [ "$actual_size" != "$expected_size" ]; then
		echo "$image is $actual_size bytes, expected exactly $expected_size for $partition -- aborting" >&2
		exit 1
	fi

	local_sha=$(sha256sum "$image" | cut -d' ' -f1)
	echo "== $partition: $image ($actual_size bytes, sha256 $local_sha) =="

	remote_tmp="/tmp/flash-$partition.img"
	echo "pushing to device..."
	adb push "$image" "$remote_tmp"

	echo "writing to /dev/block/by-name/$partition..."
	adb shell "dd if=$remote_tmp of=/dev/block/by-name/$partition bs=4M conv=fsync"

	echo "reading back and verifying..."
	remote_sha=$(adb shell "dd if=/dev/block/by-name/$partition bs=4M count=$(( (expected_size + 4*1024*1024 - 1) / (4*1024*1024) )) 2>/dev/null | head -c $expected_size | sha256sum" | cut -d' ' -f1)

	if [ "$local_sha" != "$remote_sha" ]; then
		echo "READBACK MISMATCH on $partition: wrote $local_sha, device has $remote_sha" >&2
		echo "DO NOT REBOOT -- restore from backup before proceeding" >&2
		exit 1
	fi

	echo "$partition: readback verified OK"
	adb shell "rm -f $remote_tmp"
done

echo
echo "All partitions written and verified. Reboot is a separate, explicit step."
