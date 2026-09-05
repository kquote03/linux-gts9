#!/usr/bin/env bash
# Build uniLoader for the Samsung Galaxy Tab S9 5G (SM-X716B), embedding the
# Phase 1 kernel Image + board DTB + a bring-up ramdisk as its payload.
# Assumes scripts/fetch-uniloader.sh and scripts/build-mainline-kernel.sh
# have already run. Must run inside `nix-shell` (shell.nix).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ul=${UNILOADER_SRC:-$repo_root/uniloader/upstream}
overlay=$repo_root/uniloader-overlay
outdir=${BUILD_OUT:-$repo_root/out/kernel}
kernel_image=$outdir/arch/arm64/boot/Image
kernel_dtb=$outdir/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb
bringup_ramdisk=${BRINGUP_RAMDISK:-$repo_root/out/bringup-ramdisk.cpio.gz}

if [ ! -d "$ul/.git" ]; then
	echo "uniLoader source not found at $ul -- run scripts/fetch-uniloader.sh first" >&2
	exit 1
fi
for f in "$kernel_image" "$kernel_dtb"; do
	if [ ! -f "$f" ]; then
		echo "missing build input: $f -- run scripts/build-mainline-kernel.sh first" >&2
		exit 1
	fi
done
if [ ! -f "$bringup_ramdisk" ]; then
	echo "missing build input: $bringup_ramdisk -- run scripts/build-bringup-ramdisk.sh first" >&2
	exit 1
fi

echo "== installing board file =="
mkdir -p "$ul/board/samsung"
cp "$overlay/board-gts9-5g.c" "$ul/board/samsung/board-gts9-5g.c"

echo "== patching soc/Kconfig (idempotent) =="
if ! grep -q "^	config SM8550$" "$ul/soc/Kconfig"; then
	awk -v overlay="$overlay/soc-sm8550.kconfig" '
		/^\tconfig SM8650$/ && !done {
			while ((getline line < overlay) > 0) print line
			close(overlay)
			print ""
			done = 1
		}
		{ print }
	' "$ul/soc/Kconfig" > "$ul/soc/Kconfig.new"
	mv "$ul/soc/Kconfig.new" "$ul/soc/Kconfig"
else
	echo "already patched"
fi

echo "== patching board/Kconfig device entry (idempotent) =="
if ! grep -q "config SAMSUNG_GTS9_5G" "$ul/board/Kconfig"; then
	awk -v overlay="$overlay/board-gts9-5g-device.kconfig" '
		/^endmenu$/ && !done {
			while ((getline line < overlay) > 0) print line
			close(overlay)
			done = 1
		}
		{ print }
	' "$ul/board/Kconfig" > "$ul/board/Kconfig.new"
	mv "$ul/board/Kconfig.new" "$ul/board/Kconfig"
else
	echo "already patched"
fi

echo "== patching board/Makefile (idempotent) =="
if ! grep -q "CONFIG_SAMSUNG_GTS9_5G" "$ul/board/Makefile"; then
	echo 'lib-$(CONFIG_SAMSUNG_GTS9_5G) += samsung/board-gts9-5g.o' >> "$ul/board/Makefile"
else
	echo "already patched"
fi

echo "== installing defconfig + blobs =="
cp "$overlay/gts9-5g_defconfig" "$ul/configs/gts9-5g_defconfig"
mkdir -p "$ul/blob"
cp "$kernel_image" "$ul/blob/Image"
cp "$kernel_dtb" "$ul/blob/dtb"
# Embedded as-is (gzip-compressed cpio) -- the mainline kernel's own
# initramfs unpacking auto-detects and decompresses it, same as it would
# for a normal Android boot.img ramdisk. uniLoader itself never inspects
# or decompresses this blob, just memcpy's it verbatim.
cp "$bringup_ramdisk" "$ul/blob/ramdisk"

echo "== building uniLoader (CROSS_COMPILE=aarch64-unknown-linux-gnu-) =="
# ARCH=aarch64 explicitly overrides shell.nix's ARCH=arm64 (set for the
# Linux kernel build, which names the same architecture "arm64" -- uniLoader
# names its own arch/ directory "aarch64" instead, and inherits the wrong
# value from the shell environment otherwise). HOSTCC/HOSTCXX explicitly
# override shell.nix's inherited LLVM=1 (also set for the kernel build),
# which otherwise points uniLoader's own copy of the kbuild host-tool
# machinery at bare clang-unwrapped -- the same "sys/types.h file not
# found" failure as the kernel build, same fix.
make_args=(ARCH=aarch64 CROSS_COMPILE=aarch64-unknown-linux-gnu- HOSTCC=cc HOSTCXX=c++)
make -C "$ul" "${make_args[@]}" distclean
make -C "$ul" "${make_args[@]}" gts9-5g_defconfig
make -C "$ul" "${make_args[@]}" -j"${BUILD_JOBS:-4}"

echo
echo "== build artifacts =="
find "$ul" -maxdepth 1 -iname "uniloader*" -exec ls -la {} \;
