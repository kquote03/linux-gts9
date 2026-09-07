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

pat=$repo_root/kernel/patches

# apply_unless <marker> <file> <patch>: idempotent out-of-tree kernel source
# patch application, same pattern as the sibling ubuntu-galaxy-tab-s9ultra
# port's own build script -- grep for a marker string unique to the patched
# result before applying, so re-running this script against an
# already-patched kernel/linux checkout is a no-op instead of a `patch`
# failure.
apply_unless() {
	local marker=$1 file=$2 patch_file=$3
	if ! grep -q "$marker" "$kdir/$file"; then
		echo "== applying $patch_file =="
		patch -d "$kdir" -p1 < "$pat/$patch_file"
	fi
}

# SoC/PHY-IP-level boot-chain quirk, not board- or chip-specific: mainline's
# PCIe0 QMP PHY driver never switches the GCC PIPE-clock mux off the XO
# reference onto the PHY's own recovered clock, but Samsung's SM8550
# (kalama) boot chain parks it there -- without this, the LTSSM can never
# perform receiver detection and any PCIe endpoint on this controller
# (WiFi/BT combo chip, regardless of exact model) is permanently invisible
# ("Device not found" in dmesg, confirmed live on real hardware -- DT
# wiring/regulators/GPIOs/power-sequencing all checked out fine, only the
# link itself never trained). Imported from the sibling X910 Ultra port's
# own out-of-tree patch (itself inherited from a physically-validated
# postmarketOS kernel) -- see docs/porting-log.md's Networking bring-up
# session entry and kernel/patches/unpark-pcie0-pipe-mux.patch's own header.
apply_unless 'clk_set_rate(qmp->pipe_clks\[0\].clk, ULONG_MAX)' \
	drivers/phy/qualcomm/phy-qcom-qmp-pcie.c unpark-pcie0-pipe-mux.patch

# Confirmed live on real hardware (Networking bring-up session): the PHY
# fix above alone was NOT sufficient -- "Device not found" persisted.
# Samsung's downstream cnss2 also programs AOP WLAN PDC resources over the
# QMP mailbox before first WCN power-on (this board's own stock DTS
# carries a qcom,pdc_init_table for its QCA6490 chip); mainline's
# pwrseq-qcom-wcn.c only ever gained this support for the WCN7850 config
# table entry (a patch the sibling X910 Ultra port already carries for its
# own, different chip) -- adapted here for qca6390. See
# docs/porting-log.md's Networking bring-up session entry.
apply_unless 'pwrseq_qcom_wcn_program_wlan_pdc' \
	drivers/power/sequencing/pwrseq-qcom-wcn.c \
	qca6390-pwrseq-cold-reset-aop.patch

# Confirmed live on real hardware (Networking bring-up session): both
# patches above together were STILL not sufficient -- "Device not found"
# persisted (LTSSM stuck in Detect.Quiet -- the chip's receiver termination
# was never even seen, i.e. the chip itself never powered up). Agent
# research (round 3) found this board's own stock DTS drives an XO-clock-
# enable GPIO (GPIO 204) as part of BOTH the WLAN and BT halves of this
# chip's power-up sequence; mainline's pwrseq-qcom-wcn.c already implements
# this exact xo-clk-assert/deassert mechanism generically but only ever
# wires it into the WCN6855 pdata table, never QCA6390/QCA6490's. This
# patch also reorders the AOP PDC vote to fire before any regulator/GPIO
# acquisition, matching downstream cnss2's own cnss_probe() ordering
# byte-for-byte (previously it fired after WLAN GPIO/clock acquisition --
# an approximation, not a bug ruled out, but worth being exact about). See
# docs/porting-log.md's Networking bring-up session entry.
apply_unless 'Send the AOP WLAN PDC votes first, before any regulator' \
	drivers/power/sequencing/pwrseq-qcom-wcn.c \
	qca6490-xo-clk-gpio.patch

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

echo "== installing USB Type-C stack (sm5714 TCPM + ps5169 redriver) into the kernel tree =="
# From-scratch GPL-2.0 reimplementations by ubuntu-galaxy-tab-s9ultra (SM-X910
# Ultra, same SM8550 chip generation, proven on real hardware) -- written
# after reading (not copying) Samsung's downstream drivers, using mainline's
# own TYPEC/TCPM/typec-mux frameworks instead of Samsung's private notifier
# interfaces. X716's own stock DTS independently confirms the same chips at
# the same i2c addresses (sm5714@49, usbpd-sm5714@33, ps5169@28), though the
# i2c *bus* assignments and most regulator/GPIO wiring in
# kernel/dts/sm8550-samsung-x716b.dts are carried over from X910 by analogy,
# unverified for X716 specifically -- see that file's comments.
drv=$repo_root/kernel/drivers

supply_dir=$kdir/drivers/power/supply
install -m 0644 "$drv/sm5714_battery.c" "$supply_dir/sm5714_battery.c"
if ! grep -q 'BATTERY_SM5714' "$supply_dir/Kconfig"; then
	sed -i '/^endif # POWER_SUPPLY$/i \
config BATTERY_SM5714\
\ttristate "Silicon Mitus SM5714 charger and fuel gauge"\
\tdepends on I2C\
\tdepends on IIO\
\thelp\
\t  Battery state of charge and charging status on boards that drive the\
\t  SM5714 combo PMIC from the AP, such as the Galaxy Tab S9 5G/Ultra.\
' "$supply_dir/Kconfig"
fi
grep -q 'sm5714_battery.o' "$supply_dir/Makefile" || \
	printf 'obj-$(CONFIG_BATTERY_SM5714)\t+= sm5714_battery.o\n' \
		>> "$supply_dir/Makefile"

tcpm_dir=$kdir/drivers/usb/typec/tcpm
install -m 0644 "$drv/sm5714_usbpd.c" "$tcpm_dir/sm5714_usbpd.c"
if ! grep -q 'TYPEC_SM5714' "$tcpm_dir/Kconfig"; then
	sed -i '/^endif # TYPEC_TCPM$/i \
config TYPEC_SM5714\
\ttristate "Silicon Mitus SM5714 USB Type-C and PD controller"\
\tdepends on I2C\
\tdepends on TYPEC_TCPM\
\tdepends on BATTERY_SM5714\
\thelp\
\t  USB Type-C CC and USB-PD message transport for the SM5714 PDIC.\
' "$tcpm_dir/Kconfig"
fi
grep -q 'sm5714_usbpd.o' "$tcpm_dir/Makefile" || \
	printf 'obj-$(CONFIG_TYPEC_SM5714)\t+= sm5714_usbpd.o\n' \
		>> "$tcpm_dir/Makefile"

mux_dir=$kdir/drivers/usb/typec/mux
install -m 0644 "$drv/ps5169.c" "$mux_dir/ps5169.c"
if ! grep -q 'TYPEC_MUX_PS5169' "$mux_dir/Kconfig"; then
	cat >> "$mux_dir/Kconfig" <<'KCEOF'

config TYPEC_MUX_PS5169
	tristate "Parade PS5169 Type-C redriver"
	depends on I2C
	depends on TYPEC
	depends on USB_ROLE_SWITCH
	help
	  USB 3.x and DisplayPort lane redriver used by the Galaxy Tab S9 5G/Ultra.
KCEOF
fi
grep -q 'ps5169.o' "$mux_dir/Makefile" || \
	printf 'obj-$(CONFIG_TYPEC_MUX_PS5169)\t+= ps5169.o\n' >> "$mux_dir/Makefile"

echo "== installing display panel driver into the kernel tree =="
# Display panel driver (Session 5, 2026-09-05): Samsung/Anapass ANA38407
# DDIC, part AMSA10FA01, no mainline driver exists. Forked from
# ubuntu-galaxy-tab-s9ultra's own from-scratch driver for the same DDIC
# family (different physical part) -- see that file's header and
# kernel/drivers/panel-samsung-ana38407-x716.c's own header for the
# X716-specific differences. Same idempotent install/Kconfig/Makefile
# staging pattern as the USB Type-C drivers above.
panel_dir=$kdir/drivers/gpu/drm/panel
install -m 0644 "$drv/panel-samsung-ana38407-x716.c" \
	"$panel_dir/panel-samsung-ana38407-x716.c"
if ! grep -q 'DRM_PANEL_SAMSUNG_ANA38407_X716' "$panel_dir/Kconfig"; then
	sed -i '/^endmenu$/i \
config DRM_PANEL_SAMSUNG_ANA38407_X716\
\ttristate "Samsung ANA38407 AMSA10FA01 (gts9-5g) DSI command-mode panel"\
\tdepends on OF\
\tdepends on DRM_MIPI_DSI\
\tdepends on BACKLIGHT_CLASS_DEVICE\
' "$panel_dir/Kconfig"
fi
grep -q 'panel-samsung-ana38407-x716.o' "$panel_dir/Makefile" || \
	printf 'obj-$(CONFIG_DRM_PANEL_SAMSUNG_ANA38407_X716)\t+= panel-samsung-ana38407-x716.o\n' \
		>> "$panel_dir/Makefile"

echo "== installing touchscreen driver into the kernel tree =="
# fts1ba90a touch controller (Session 6, 2026-09-06): no usable mainline
# driver exists for this chip -- ported from Samsung's downstream
# fts1ba90a source. Same idempotent install/Kconfig/Makefile staging
# pattern as the other from-scratch drivers above.
ts_dir=$kdir/drivers/input/touchscreen
install -m 0644 "$drv/touchscreen-fts1ba90a-x716.c" \
	"$ts_dir/fts1ba90a-x716.c"
if ! grep -q 'TOUCHSCREEN_FTS1BA90A_X716' "$ts_dir/Kconfig"; then
	sed -i '/^endif$/i \
config TOUCHSCREEN_FTS1BA90A_X716\
\ttristate "STMicroelectronics fts1ba90a touchscreen (gts9-5g)"\
\tdepends on I2C\
\thelp\
\t  STMicroelectronics fts1ba90a touch controller as fitted to the\
\t  Galaxy Tab S9 5G.\
' "$ts_dir/Kconfig"
fi
grep -q 'fts1ba90a-x716.o' "$ts_dir/Makefile" || \
	printf 'obj-$(CONFIG_TOUCHSCREEN_FTS1BA90A_X716)\t+= fts1ba90a-x716.o\n' \
		>> "$ts_dir/Makefile"

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
