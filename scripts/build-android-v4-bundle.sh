#!/usr/bin/env bash
# Package the raw mainline kernel Image + a ramdisk + the board DTB into
# boot.img/init_boot.img/vendor_boot.img/dtbo.img, matching this device's
# confirmed partition sizes and header format (measured from the
# 2026-09-04 TWRP backup -- see docs/hardware-facts.md). No AVB signing
# keys are used: vbmeta on this device already has verification disabled
# (AVB flags=2, confirmed), so these footers are structural only
# (--algorithm NONE), not cryptographic.
#
# uniLoader was tried as an intermediate bootloader in boot's kernel slot
# and dropped after five inconclusive flash attempts (zero diagnostic
# signal despite verified-correct code). Those five attempts, plus two
# more with a raw kernel Image, all turned out to fail identically at
# ABL's own DTB/DTBO validation step ("No Valid Dtb" / "Unable to find
# the Board Dtb" / "Error: Board Dtbo blob not found" -- see
# docs/hardware-facts.md's root-cause section) -- never reaching the
# kernel/payload slot at all. This script now follows the validated,
# real-hardware-proven recipe from ubuntu-galaxy-tab-s9ultra/ (the SM-X910
# Ultra port -- same SM8550 "kalama" chip generation as this device):
# gzip the kernel and append the board DTB directly after it, and make
# dtbo.img deliberately NOT a DT table (a zero-filled blob) so ABL can't
# take its downstream "ufdt" merge path, which is what was rejecting our
# mainline DTB every time. uniloader-overlay/ and scripts/build-uniloader.sh
# remain in the repo, unused, in case it's worth revisiting later.
#
# Produces files under out/android/ -- nothing is flashed by this script.
# See docs/boot-strategy.md for the pre-flash checklist that must be
# followed before any of these are written to the device.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
android_out=$outdir/android
mkdir -p "$android_out"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

mkbootimg=$repo_root/third_party/android-tools/mkbootimg/mkbootimg.py
avbtool=$repo_root/third_party/android-tools/avb/avbtool.py

kernel_image=${KERNEL_IMAGE:-$repo_root/out/kernel/arch/arm64/boot/Image}
ramdisk=${BRINGUP_RAMDISK:-$repo_root/out/bringup-ramdisk.cpio.gz}
board_dtb=${BOARD_DTB:-$repo_root/out/kernel/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb}

# init_boot (8 MiB) and vendor_boot (96 MiB) each carry their own ramdisk
# -- ABL concatenates them into one combined initramfs at boot (standard
# mainline behavior: multiple concatenated cpio archives, later entries
# overriding earlier ones for the same path -- not an Android-specific
# trick). They default to the SAME small ramdisk (historically both were
# the tiny debug bring-up ramdisk, comfortably under either partition's
# size), but can be pointed at different inputs independently -- needed
# once a real rootfs (e.g. the Buildroot Weston rootfs, ~15-18 MiB) is
# bigger than init_boot's fixed 8 MiB but still fits vendor_boot's 96 MiB
# easily. See docs/porting-log.md's Session 5 entry for why this split
# was added: a first attempt just pointing BRINGUP_RAMDISK at the Weston
# rootfs failed outright ("Image size ... exceeds maximum image size ...
# in order to fit in a partition size of 8388608") since it defaulted
# into BOTH slots including the too-small init_boot one.
init_boot_ramdisk=${INIT_BOOT_RAMDISK:-$ramdisk}
vendor_ramdisk_src=${VENDOR_RAMDISK:-$ramdisk}

for f in "$kernel_image" "$init_boot_ramdisk" "$vendor_ramdisk_src" "$board_dtb"; do
	if [ ! -f "$f" ]; then
		echo "missing build input: $f" >&2
		exit 1
	fi
done

# Samsung's boot chain expects the generic/vendor ramdisks in legacy LZ4
# framing, not gzip -- confirmed by ubuntu-galaxy-tab-s9ultra's own script
# comment: "stock uses the legacy LZ4 stream format... a gzip generic
# ramdisk is a valid Android v4 image but Linux rejects the resulting
# initrd with 'invalid magic at start of compressed archive'." Our own
# ramdisk builders produce gzip cpio, so convert here rather than
# changing either of those scripts' output format.
to_lz4() {
	local src=$1 dst=$2
	case $(head -c4 "$src" | od -An -tx1 | tr -d ' \n') in
		02214c18)
			printf '%s' "$src"
			;;
		1f8b*)
			gzip -dc "$src" | lz4 -l -12 - "$dst" >/dev/null
			printf '%s' "$dst"
			;;
		*)
			echo "ramdisk $src is neither gzip nor legacy LZ4; refusing" >&2
			exit 1
			;;
	esac
}
lz4_ramdisk=$(to_lz4 "$init_boot_ramdisk" "$workdir/init-boot-ramdisk.lz4")
vendor_lz4_ramdisk=$(to_lz4 "$vendor_ramdisk_src" "$workdir/vendor-ramdisk.lz4")

# Confirmed partition sizes (docs/hardware-facts.md) -- avbtool needs these
# to size the footer correctly, and used below to fail fast with a clear
# message (rather than avbtool's own less obvious error) if a ramdisk is
# too big for the slot it's headed for.
boot_size=100663296
init_boot_size=8388608
vendor_boot_size=100663296
dtbo_size=16777216

check_fits() {
	local file=$1 partition_size=$2 label=$3
	local size
	size=$(stat -c%s "$file")
	# avbtool's hash footer itself needs room too -- same margin avbtool
	# already enforces internally, checked here just to fail earlier with
	# a clearer message naming the actual ramdisk that's too big.
	if [ "$size" -gt $((partition_size - 69632)) ]; then
		echo "$label ramdisk ($file, $size bytes) is too big for its" \
			"partition ($partition_size bytes) -- point INIT_BOOT_RAMDISK/" \
			"VENDOR_RAMDISK at something smaller, or move it to the other slot" >&2
		exit 1
	fi
}
check_fits "$lz4_ramdisk" "$init_boot_size" "init_boot"
check_fits "$vendor_lz4_ramdisk" "$vendor_boot_size" "vendor_boot"

# fw_devlink=off + deferred_probe_timeout=10 was tried 2026-09-05 to test
# whether late boot was stuck waiting indefinitely in the deferred-probe
# mechanism -- confirmed via the userspace-reached vibration burst (see
# docs/porting-log.md) that userspace is fine regardless, so that test's
# job was done. Reverted here after a deep investigation found it was
# actively HURTING one of the new USB Type-C drivers: ps5169.c's probe()
# calls fwnode_usb_role_switch_get(), a legitimate supplier dependency on
# &usb_1's role-switch registration that needs an -EPROBE_DEFER retry --
# with fw_devlink off and only a 10s deferred_probe_timeout, the driver
# core gave up permanently instead of retrying once usb_1 was ready.
cmdline="earlycon loglevel=8 log_buf_len=4M panic=10 clk_ignore_unused pd_ignore_unused regulator_ignore_unused initcall_debug"

echo "== boot.img (kernel = gzip'd mainline Image with board DTB appended, no ramdisk -- GKI-style split, ramdisk lives in init_boot) =="
# ABL's own log unconditionally shows a "Decompressing kernel image" step
# (observed in attempt 6's /proc/last_kmsg capture) -- direct evidence it
# expects a compressed kernel in this slot, not a raw Image. The DTB is
# concatenated directly after the gzip stream (the classic ARM64
# "Image.gz-dtb" appended-DTB convention), matching
# ubuntu-galaxy-tab-s9ultra's validated recipe exactly.
boot_kernel=$workdir/Image.gz-dtb
gzip -c "$kernel_image" > "$workdir/Image.gz"
cat "$workdir/Image.gz" "$board_dtb" > "$boot_kernel"

python3 "$mkbootimg" \
	--header_version 4 \
	--kernel "$boot_kernel" \
	--cmdline "" \
	--os_version 15.0.0 \
	--os_patch_level 2026-09 \
	-o "$android_out/boot.img"
python3 "$avbtool" add_hash_footer \
	--image "$android_out/boot.img" \
	--partition_name boot \
	--partition_size "$boot_size" \
	--algorithm NONE

echo "== init_boot.img (generic ramdisk only) =="
python3 "$mkbootimg" \
	--header_version 4 \
	--ramdisk "$lz4_ramdisk" \
	-o "$android_out/init_boot.img"
python3 "$avbtool" add_hash_footer \
	--image "$android_out/init_boot.img" \
	--partition_name init_boot \
	--partition_size "$init_boot_size" \
	--algorithm NONE

echo "== vendor_boot.img (DTB + vendor cmdline + vendor ramdisk) =="
# base/kernel_offset/ramdisk_offset/tags_offset/dtb_offset match the stock
# vendor_boot header fields measured from the TWRP backup (see
# docs/hardware-facts.md) -- kept identical on the theory that matching
# Samsung's own known-working layout is the safer first attempt.
python3 "$mkbootimg" \
	--header_version 4 \
	--base 0x80000000 \
	--kernel_offset 0x8000 \
	--ramdisk_offset 0x02000000 \
	--tags_offset 0x01e00000 \
	--pagesize 4096 \
	--dtb "$board_dtb" \
	--dtb_offset 0x1f00000 \
	--vendor_cmdline "$cmdline" \
	--vendor_ramdisk "$vendor_lz4_ramdisk" \
	--vendor_boot "$android_out/vendor_boot.img"
python3 "$avbtool" add_hash_footer \
	--image "$android_out/vendor_boot.img" \
	--partition_name vendor_boot \
	--partition_size "$vendor_boot_size" \
	--algorithm NONE

echo "== dtbo.img (deliberately NOT a DT table, forces ABL past its downstream ufdt merge path onto vendor_boot's DTB directly) =="
# An earlier version of this script built a structurally-valid (if,
# earlier this session, buggy-header) empty DTBO table here. That was the
# wrong fix: ANY parseable DT table -- empty or not -- makes ABL take its
# downstream "ufdt" merge path and reject a mainline base DTB outright
# ("No Valid Dtb" / "Unable to find the Board Dtb" / "Error: Board Dtbo
# blob not found", confirmed identically across all seven attempts before
# this fix -- see docs/hardware-facts.md). ubuntu-galaxy-tab-s9ultra
# (SM-X910 Ultra, same SM8550 chip generation, proven on real hardware)
# uses exactly this fix: a zero-filled blob with no DT-table magic at all,
# so ABL can't take that path and falls back to vendor_boot's DTB,
# unmerged. Its own validate-bundle.sh asserts this by name: a dtbo.img
# whose first 4 bytes parse as the DT table magic fails its build with
# "dtbo.img is a DT table; ABL will take the ufdt path and reject the DTB".
rm -f "$android_out/dtbo.img"
truncate -s 4096 "$android_out/dtbo.img"
python3 "$avbtool" add_hash_footer \
	--image "$android_out/dtbo.img" \
	--partition_name dtbo \
	--partition_size "$dtbo_size" \
	--algorithm NONE

echo
echo "== bundle artifacts (not flashed -- see docs/boot-strategy.md) =="
ls -la "$android_out"
for f in boot init_boot vendor_boot dtbo; do
	sha256sum "$android_out/$f.img"
done
