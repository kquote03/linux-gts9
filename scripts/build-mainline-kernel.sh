#!/usr/bin/env bash
# Build the mainline kernel Image + board DTB for the Samsung Galaxy Tab S9
# 5G (SM-X716B). Assumes scripts/fetch-mainline.sh has already pinned the
# kernel checkout. Must run inside `nix-shell` (shell.nix).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kdir=${LINUX_SRC:-$repo_root/kernel/linux}
outdir=${BUILD_OUT:-$repo_root/out/kernel}
board_dts=sm8550-samsung-x716b.dts
board_dtb=sm8550-samsung-x716b.dtb
qcom_dts_dir=$kdir/arch/arm64/boot/dts/qcom

if [ ! -d "$kdir/.git" ]; then
	echo "kernel source not found at $kdir -- run scripts/fetch-mainline.sh first" >&2
	exit 1
fi

# Kbuild's LLVM=1 points HOSTCC/HOSTCXX at bare clang-unwrapped even when an
# environment-exported override is present -- only a command-line-supplied
# HOSTCC/HOSTCXX takes effect. Same is true of KCFLAGS (needed for
# -resource-dir, see shell.nix -- bare clang-unwrapped doesn't auto-find its
# own builtin headers like arm_neon.h on NixOS). Confirmed both by
# reproducing the failures with only the environment-exported form set.
make_args=(ARCH=arm64 LLVM=1 HOSTCC=cc HOSTCXX=c++ "KCFLAGS=${KCFLAGS:-}" O="$outdir")

echo "== installing board DTS into the kernel tree =="
cp "$repo_root/kernel/dts/$board_dts" "$qcom_dts_dir/$board_dts"
if ! grep -q "^dtb-\$(CONFIG_ARCH_QCOM)[[:space:]]*+= $board_dtb\$" "$qcom_dts_dir/Makefile"; then
	echo "dtb-\$(CONFIG_ARCH_QCOM)	+= $board_dtb" >> "$qcom_dts_dir/Makefile"
fi

echo "== installing sec-log driver into the kernel tree =="
cp "$repo_root/kernel/drivers/samsung-x716-sec-log.c" "$kdir/drivers/misc/x716-sec-log.c"
if ! grep -q "^config X716_SEC_LOG$" "$kdir/drivers/misc/Kconfig"; then
	awk -v overlay="$repo_root/kernel/config/x716-sec-log.kconfig" '
		/^endmenu$/ && !done {
			while ((getline line < overlay) > 0) print line
			close(overlay)
			done = 1
		}
		{ print }
	' "$kdir/drivers/misc/Kconfig" > "$kdir/drivers/misc/Kconfig.new"
	mv "$kdir/drivers/misc/Kconfig.new" "$kdir/drivers/misc/Kconfig"
fi
if ! grep -q "CONFIG_X716_SEC_LOG" "$kdir/drivers/misc/Makefile"; then
	echo 'obj-$(CONFIG_X716_SEC_LOG)	+= x716-sec-log.o' >> "$kdir/drivers/misc/Makefile"
fi

mkdir -p "$outdir"

echo "== defconfig =="
make -C "$kdir" "${make_args[@]}" defconfig

echo "== merging config fragments =="
"$kdir/scripts/kconfig/merge_config.sh" -O "$outdir" -m "$outdir/.config" \
	"$repo_root/kernel/config/config-mainline.aarch64" \
	"$repo_root/kernel/config/config-x716.fragment"

make -C "$kdir" "${make_args[@]}" olddefconfig

echo "== verifying no fragment-requested symbol was silently dropped =="
fail=0
for frag in "$repo_root/kernel/config/config-mainline.aarch64" "$repo_root/kernel/config/config-x716.fragment"; do
	while IFS='=' read -r key val; do
		[ -z "$key" ] && continue
		case "$key" in \#*) continue ;; esac
		actual=$(grep -m1 "^$key=" "$outdir/.config" || true)
		if [ "$actual" != "$key=$val" ]; then
			echo "MISMATCH: $key wanted $val, .config has: ${actual:-<unset>}" >&2
			fail=1
		fi
	done < <(grep -E '^CONFIG_[A-Z0-9_]+=' "$frag")
done
if [ "$fail" -ne 0 ]; then
	echo "one or more fragment symbols were dropped/changed by dependency resolution -- see above" >&2
	exit 1
fi
echo "all fragment symbols present as requested"

echo "== building Image (uncompressed -- uniLoader embeds a raw Image, not Image.gz) =="
make -C "$kdir" "${make_args[@]}" -j"${BUILD_JOBS:-4}" Image

echo "== building board DTB =="
make -C "$kdir" "${make_args[@]}" -j"$(nproc)" "qcom/$board_dtb"

image=$outdir/arch/arm64/boot/Image
dtb=$outdir/arch/arm64/boot/dts/qcom/$board_dtb

echo
echo "== build artifacts =="
ls -la "$image" "$dtb"
echo "Image sha256:  $(sha256sum "$image" | cut -d' ' -f1)"
echo "dtb sha256:    $(sha256sum "$dtb" | cut -d' ' -f1)"
echo "kernel release: $(cat "$outdir/include/config/kernel.release" 2>/dev/null || echo unknown)"
