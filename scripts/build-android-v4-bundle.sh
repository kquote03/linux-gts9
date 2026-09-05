#!/usr/bin/env bash
# Package uniLoader + a ramdisk + the board DTB into boot.img/init_boot.img/
# vendor_boot.img/dtbo.img, matching this device's confirmed partition
# sizes and header format (measured from the 2026-09-04 TWRP backup -- see
# docs/hardware-facts.md). No AVB signing keys are used: vbmeta on this
# device already has verification disabled (AVB flags=2, confirmed), so
# these footers are structural only (--algorithm NONE), not cryptographic.
#
# Produces files under out/android/ -- nothing is flashed by this script.
# See docs/boot-strategy.md for the pre-flash checklist that must be
# followed before any of these are written to the device.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
android_out=$outdir/android
mkdir -p "$android_out"

mkbootimg=$repo_root/third_party/android-tools/mkbootimg/mkbootimg.py
avbtool=$repo_root/third_party/android-tools/avb/avbtool.py

# CONFIG_COMPRESS_GZIP=y also builds uniLoader.gz; which of the two ABL
# actually wants is unconfirmed (see docs/hardware-facts.md) -- defaulting
# to the uncompressed binary since that's the more conservative choice
# structurally (no assumption that ABL will decompress it), overridable via
# UNILOADER_KERNEL for the first flash attempt to try the alternative.
uniloader=${UNILOADER_KERNEL:-$repo_root/uniloader/upstream/uniLoader}
ramdisk=${BRINGUP_RAMDISK:-$repo_root/out/bringup-ramdisk.cpio.gz}
board_dtb=${BOARD_DTB:-$repo_root/out/kernel/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb}

for f in "$uniloader" "$ramdisk" "$board_dtb"; do
	if [ ! -f "$f" ]; then
		echo "missing build input: $f" >&2
		exit 1
	fi
done

# Confirmed partition sizes (docs/hardware-facts.md) -- avbtool needs these
# to size the footer correctly.
boot_size=100663296
init_boot_size=8388608
vendor_boot_size=100663296
dtbo_size=16777216

cmdline="earlycon loglevel=8 log_buf_len=4M panic=10 clk_ignore_unused pd_ignore_unused regulator_ignore_unused initcall_debug"

echo "== boot.img (kernel = uniLoader, no ramdisk -- GKI-style split, ramdisk lives in init_boot) =="
python3 "$mkbootimg" \
	--header_version 4 \
	--kernel "$uniloader" \
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
	--ramdisk "$ramdisk" \
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
	--vendor_ramdisk "$ramdisk" \
	--vendor_boot "$android_out/vendor_boot.img"
python3 "$avbtool" add_hash_footer \
	--image "$android_out/vendor_boot.img" \
	--partition_name vendor_boot \
	--partition_size "$vendor_boot_size" \
	--algorithm NONE

echo "== dtbo.img (inert no-op table, forces ABL to fall back to the appended/vendor_boot DTB) =="
noop_dts=$(mktemp --suffix=.dts)
cat > "$noop_dts" <<'EOF'
/dts-v1/;
/plugin/;
/ {
	fragment@0 {
		target-path = "/";
		__overlay__ { };
	};
};
EOF
noop_dtbo=$(mktemp --suffix=.dtbo)
dtc -@ -I dts -O dtb -o "$noop_dtbo" "$noop_dts"
mkdtboimg=$repo_root/third_party/android-tools/mkbootimg/mkdtboimg.py
if [ -f "$mkdtboimg" ]; then
	python3 "$mkdtboimg" create "$android_out/dtbo.img" "$noop_dtbo"
else
	# mkdtboimg.py isn't vendored (only mkbootimg/repack/unpack + avbtool
	# were) -- a single-entry DTBO table's header is simple enough to build
	# directly: magic, tot_size, header_size=32, dt_entry_size=32,
	# dt_entry_count=1, entries_offset=32, then one entry (size, offset,
	# id=0, rev=0, 4 reserved words), then the dtbo blob itself.
	python3 - "$noop_dtbo" "$android_out/dtbo.img" <<'PYEOF'
import struct, sys
dtbo_path, out_path = sys.argv[1], sys.argv[2]
with open(dtbo_path, "rb") as f:
	dtbo = f.read()
header_size = 32
entry_size = 32
entries_offset = header_size
dtbo_offset = entries_offset + entry_size
total_size = dtbo_offset + len(dtbo)
header = struct.pack(">IIIIIII",
	0xd7b7ab1e, total_size, header_size, entry_size, 1, entries_offset, 4096)
entry = struct.pack(">IIIIIIII", len(dtbo), dtbo_offset, 0, 0, 0, 0, 0, 0)
with open(out_path, "wb") as f:
	f.write(header)
	f.write(entry)
	f.write(dtbo)
PYEOF
fi
python3 "$avbtool" add_hash_footer \
	--image "$android_out/dtbo.img" \
	--partition_name dtbo \
	--partition_size "$dtbo_size" \
	--algorithm NONE
rm -f "$noop_dts" "$noop_dtbo"

echo
echo "== bundle artifacts (not flashed -- see docs/boot-strategy.md) =="
ls -la "$android_out"
for f in boot init_boot vendor_boot dtbo; do
	sha256sum "$android_out/$f.img"
done
