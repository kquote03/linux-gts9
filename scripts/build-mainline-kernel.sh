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

# The following 9 patches are adopted verbatim from gts9wifi-fedora (the
# real, mature Fedora port for the Wi-Fi-only sibling tablet, gts9wifi-
# fedora pivot -- see docs/porting-log.md's Session 9 entry) rather than
# independently re-derived: each fixes a genuine mainline-tree/SoC-IP-level
# gap (not board-specific behavior) that this port's own new DTS content
# (kernel/dts/sm8550-samsung-x716b.dts's speaker/DP-altmode/PPS/USB-PD
# nodes) now depends on to actually do anything. Applied in the same
# relative order gts9wifi-fedora's own prepare.sh uses (plain alphabetical
# `patch -p1` over patches/*.patch) since two of these have real
# apply-order dependencies on each other (the tcpm pair; the three msm-dp
# ones share overlapping context in dp_drm.c/dp_display.c).
#
# Deliberately NOT ported from their fuller patch set: add-gts9wifi-dtb.patch
# (their kernel.spec's own Makefile dtb-y registration -- this project builds
# the board DTB directly via its own pipeline, see below, not via an
# upstream Makefile dtb-y list); add-samsung-sec-log-console.patch and
# keep-sec-log-previous-index-current.patch (this project already carries
# its own from-scratch sec-log driver, kernel/drivers/x716-sec-log.c --
# see docs/porting-log.md, "keep our own sec-log driver rather than
# duplicating theirs" per the gts9wifi-fedora pivot plan);
# build-wcn-pcie-providers-in.patch (WiFi already confirmed working on
# real hardware without it -- Networking bring-up session -- and this
# project's own config-x716.fragment already sets CONFIG_QCOM_QMI_HELPERS=y
# explicitly); expose-separate-gpu-kms-resources.patch (fixes an Xorg
# modesetting-DDX-specific `msm.separate_gpu_kms=1` edge case; this port's
# desktop stack is Wayland/GNOME-mutter talking to KMS directly, and
# nothing here sets that module param, so the fix has nothing to attach to).

# phy: nxp: ptn3222 -- without this, the mainline driver silently ignores
# our DTS's `qcom,param-override-seq` property entirely (it isn't even
# read). Confirmed: this is the one specific patch that gives that
# property any effect at all.
apply_unless 'PTN3222_MAX_INIT_CELLS' \
	drivers/phy/phy-nxp-ptn3222.c configure-nxp-ptn3222-from-dt.patch

# printk: Samsung's ABL appends `console=null` after the vendor command
# line, which would otherwise silently kill the framebuffer console on
# any Tab S9 model sharing this bootloader behavior -- opt-in, harmless
# unless `ignore_console_null` is passed.
apply_unless 'ignore_console_null_setup' \
	kernel/printk/printk.c ignore-console-null.patch

# phy: snps-eusb2 -- matches Samsung's downstream SM8550 PLL/POR sequencing
# (a post-POR delay + CPBIAS=1 instead of 0); without it the eUSB2 PHY
# reaches DWC3 gadget mode fine but a real USB host cannot read the
# device's descriptor -- exactly the class of bug blocking real host mode.
apply_unless 'Match Samsung SM8550 sequencing before enabling the PHY' \
	drivers/phy/phy-snps-eusb2.c match-samsung-sm8550-eusb2-phy-init.patch

# drm/msm/dp (1 of 3, apply first): our &mdss_dp0 routes DisplayPort
# through a usb-c-connector node, not a DRM bridge, so the transparent
# bridge chain ends in -EPROBE_DEFER -- which otherwise also blocks the
# shared MSM DRM component master (and therefore the unrelated internal
# DSI panel) from binding at all, not just external DP.
apply_unless 'ret != -EPROBE_DEFER' \
	drivers/gpu/drm/msm/dp/dp_display.c msm-dp-allow-unresolved-usbc-bridge.patch

# drm/msm/dp (2 of 3): keeps the DP controller's own fwnode on the
# terminal bridge, so out-of-band Type-C HPD notifications (carried only
# over USB-PD on this hardware, no physical HPD pin) can find it.
apply_unless 'firmware node on the terminal bridge' \
	drivers/gpu/drm/msm/dp/dp_drm.c msm-dp-associate-bridge-of-node.patch

# drm/msm/dp (3 of 3): implements our DTS's `qcom,defer-hpd-until-first-
# resume` property -- without this patch that property is inert, same
# class of gap as the ptn3222 one above. Works around a real cold-boot
# ordering issue where activating the external DPU encoder before the
# ANA38407 panel's first platform suspend/resume cycle resets the board.
apply_unless 'defer_hpd_until_resume' \
	drivers/gpu/drm/msm/dp/dp_drm.h msm-dp-defer-oob-hpd-until-resume.patch

# ASoC: qcom: sc8280xp -- AudioReach programs the LPASS side of MI2S but
# never tells the codec side its bit-clock rate or format; without this,
# an MI2S codec (our CS35L45 amplifiers) keeps its reset-default format
# and produces no audio at all, not even an error.
apply_unless 'MI2S_BCLK_RATE' \
	sound/soc/qcom/sc8280xp.c set-mi2s-codec-dai-format.patch

# usb: typec: tcpm (1 of 2, apply first): lets TCPM recover when a
# still-powered charge-through dock retains its Source/UFP role across a
# host reboot (both ends otherwise claim UFP and TCPM loops in error
# recovery). Opt-in (`adopt_retained_source_ufp`); normal Source/DFP
# partners are unaffected.
apply_unless 'adopt_retained_source_ufp' \
	include/linux/usb/tcpm.h tcpm-adopt-retained-source-ufp-role.patch

# usb: typec: tcpm (2 of 2): the matching Sink/DFP-side half of the fix
# above -- restores the retained data role before a still-powered
# Source/UFP dock sends any PD message, instead of only reacting after
# the fact.
apply_unless 'consume_retained_sink_dfp' \
	include/linux/usb/tcpm.h tcpm-use-retained-sink-data-role.patch

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

echo "== installing PPS direct-charge pump driver into the kernel tree =="
# sm5440_direct.c (gts9wifi-fedora pivot): adopted verbatim from
# gts9wifi-fedora's own from-scratch driver (kernel/drivers/sm5440_direct.c
# here, gts9wifi-fedora's kernel/files/sm5440_direct.c there) -- a small,
# mainline-framework-only driver (TCPM/power_supply, no Samsung private
# notifiers) that requests a conservative PPS operating point and hands the
# battery path over from sm5714_battery, which already exports the exact
# hook (`sm5714_battery_set_direct_charge`) and power_supply name
# ("sm5714-battery") this driver expects -- confirmed directly against our
# own kernel/drivers/sm5714_battery.c before porting this. Same idempotent
# install/Kconfig/Makefile staging pattern as the USB Type-C stack above.
sm5440_supply_dir=$kdir/drivers/power/supply
install -m 0644 "$drv/sm5440_direct.c" "$sm5440_supply_dir/sm5440_direct.c"
if ! grep -q 'CHARGER_SM5440_DIRECT' "$sm5440_supply_dir/Kconfig"; then
	sed -i '/^endif # POWER_SUPPLY$/i \
config CHARGER_SM5440_DIRECT\
\ttristate "Silicon Mitus SM5440 2:1 direct charge pump"\
\tdepends on I2C\
\tdepends on TYPEC_TCPM\
\tdepends on BATTERY_SM5714\
\thelp\
\t  PPS direct-charge pump on boards that pair the SM5714 switching\
\t  charger with a separate SM5440 charge pump, such as the Galaxy\
\t  Tab S9 5G.\
' "$sm5440_supply_dir/Kconfig"
fi
grep -q 'sm5440_direct.o' "$sm5440_supply_dir/Makefile" || \
	printf 'obj-$(CONFIG_CHARGER_SM5440_DIRECT)\t+= sm5440_direct.o\n' \
		>> "$sm5440_supply_dir/Makefile"

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

echo "== installing S Pen (Wacom WEZ01) driver into the kernel tree =="
# Ported verbatim from gts9wifi-fedora (gts9wifi-fedora pivot); digitizer
# presence on this exact X716B unit confirmed via a real on-device
# wez01_gts9.bin firmware blob -- see kernel/dts/sm8550-samsung-x716b.dts's
# i2c3 node comment. Same idempotent install/Kconfig/Makefile pattern.
install -m 0644 "$drv/touchscreen-wacom-wez01-x716.c" \
	"$ts_dir/wacom-wez01-x716.c"
if ! grep -q 'TOUCHSCREEN_WACOM_WEZ01_X716' "$ts_dir/Kconfig"; then
	sed -i '/^endif$/i \
config TOUCHSCREEN_WACOM_WEZ01_X716\
\ttristate "Wacom WEZ01 EMR digitizer (gts9-5g)"\
\tdepends on I2C\
\thelp\
\t  Wacom WEZ01 EMR S Pen digitizer as fitted to the Galaxy Tab S9 5G.\
' "$ts_dir/Kconfig"
fi
grep -q 'wacom-wez01-x716.o' "$ts_dir/Makefile" || \
	printf 'obj-$(CONFIG_TOUCHSCREEN_WACOM_WEZ01_X716)\t+= wacom-wez01-x716.o\n' \
		>> "$ts_dir/Makefile"

mkdir -p "$outdir"

echo "== defconfig =="
make -C "$kdir" "${make_args[@]}" defconfig

echo "== merging config fragments =="
"$kdir/scripts/kconfig/merge_config.sh" -O "$outdir" -m "$outdir/.config" \
	"$repo_root/kernel/config/config-mainline.aarch64" \
	"$repo_root/kernel/config/config-x716.fragment"

make -C "$kdir" "${make_args[@]}" olddefconfig

echo "== verifying no board-fragment-requested symbol was silently dropped =="
# Only config-x716.fragment is checked strictly: those are this project's
# own deliberate, board-specific asks, and dependency resolution silently
# dropping one of them is a real regression. config-mainline.aarch64 is
# now a vendored 12,700-line generic base (gts9wifi-fedora's own
# comprehensive config, see that file's header) -- resolving some of its
# symbols differently against this project's specific patched tree/
# from-scratch board drivers is expected, not a build-breaking
# regression, so it's deliberately not held to the same airtight
# standard.
fail=0
for frag in "$repo_root/kernel/config/config-x716.fragment"; do
	while IFS='=' read -r key val; do
		[ -z "$key" ] && continue
		case "$key" in \#*) continue ;; esac
		actual=$(grep -m1 "^$key=" "$outdir/.config" || true)
		# Kconfig never writes "KEY=n" -- an explicitly-off boolean/tristate
		# is represented as "# KEY is not set" instead. Recognize that form
		# too, or every "=n" fragment request (e.g. CONFIG_SECURITY_SELINUX=n)
		# falsely reports as dropped even when it landed correctly.
		if [ "$val" = "n" ] && grep -qx "# $key is not set" "$outdir/.config"; then
			continue
		fi
		if [ "$actual" != "$key=$val" ]; then
			echo "MISMATCH: $key wanted $val, .config has: ${actual:-<unset>}" >&2
			fail=1
		fi
	done < <(grep -E '^CONFIG_[A-Z0-9_]+=' "$frag")
done
if [ "$fail" -ne 0 ]; then
	echo "one or more board-fragment symbols were dropped/changed by dependency resolution -- see above" >&2
	exit 1
fi
echo "all board-fragment symbols present as requested"

echo "== building Image (uncompressed -- uniLoader embeds a raw Image, not Image.gz) =="
make -C "$kdir" "${make_args[@]}" -j"${BUILD_JOBS:-4}" Image

echo "== building board DTB =="
make -C "$kdir" "${make_args[@]}" -j"$(nproc)" "qcom/$board_dtb"

kernel_release=$(cat "$outdir/include/config/kernel.release" 2>/dev/null || echo unknown)

# This project's first real use of loadable kernel modules -- the new,
# much larger config-mainline.aarch64 base (vendored from gts9wifi-fedora)
# enables ~1800 modules for generic desktop hardware (HID vendor quirks,
# extra filesystems, more USB/sound device classes) that config-x716.fragment
# never had to force =y itself, since they're not needed to boot this
# board. gts9wifi-fedora gets modules_install for free from RPM kernel
# packaging (kernel.spec); this project's own pipeline deliberately skips
# RPM (Phase 4), so do it directly here instead. depmod runs once here,
# self-contained, against this fresh INSTALL_MOD_PATH -- so
# scripts/build-fedora-rootfs.sh only needs to copy the resulting tree
# in, no chroot/re-run needed.
echo "== building kernel modules =="
make -C "$kdir" "${make_args[@]}" -j"${BUILD_JOBS:-4}" modules

echo "== installing kernel modules =="
modules_out=$outdir/modules-out
rm -rf "$modules_out"
make -C "$kdir" "${make_args[@]}" INSTALL_MOD_PATH="$modules_out" modules_install

echo "== running depmod =="
depmod -b "$modules_out" "$kernel_release"

image=$outdir/arch/arm64/boot/Image
dtb=$outdir/arch/arm64/boot/dts/qcom/$board_dtb
moddir=$modules_out/lib/modules/$kernel_release

echo
echo "== build artifacts =="
ls -la "$image" "$dtb"
echo "Image sha256:  $(sha256sum "$image" | cut -d' ' -f1)"
echo "dtb sha256:    $(sha256sum "$dtb" | cut -d' ' -f1)"
echo "kernel release: $kernel_release"
if [ -d "$moddir" ]; then
	# CONFIG_MODULE_COMPRESS_ZSTD (from the new vendored base config)
	# means installed modules are *.ko.zst, not bare *.ko -- match both.
	mod_count=$(find "$moddir" -name '*.ko' -o -name '*.ko.zst' | wc -l)
	mod_size=$(du -sh "$moddir" | cut -f1)
	echo "modules:        $mod_count module files, $mod_size, at $moddir"
else
	echo "modules:        WARNING -- $moddir not found after modules_install" >&2
fi
