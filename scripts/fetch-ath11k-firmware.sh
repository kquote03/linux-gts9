#!/usr/bin/env bash
# Fetch WiFi/BT firmware for this device's real combo chip.
#
# **Correction from real-hardware testing (Networking bring-up session,
# full-fix boot)**: the WLAN and BT halves of this chip identify as two
# *different* things to their respective mainline subsystems, independently
# and via entirely separate hardware-readback paths -- neither is a guess:
#   - WLAN, via ath11k_pci's MHI SoC-ID readback over PCIe (dmesg:
#     "ath11k_pci 0000:01:00.0: wcn6855 hw2.1"): identifies as
#     **WCN6855 hw2.1**, not QCA6390/QCA6490 as this device's own stock
#     downstream DTS naming (`qcom,cnss-qca6490`) implied.
#   - BT, via hci_qca's live HCI vendor-command version readback over
#     UART14 (dmesg: "Bluetooth: hci0: setting up ROME/QCA6390", "QCA ROM
#     Version: 0x00000201"): identifies as **QCA6390** (soc_type
#     QCA_QCA6390 in drivers/bluetooth/btqca.c), rom_ver **0x21** -- not
#     the 0x20 this script originally guessed.
# See docs/porting-log.md's Networking bring-up session entry for the full
# dmesg citations.
#
# ## WiFi firmware
#
# ath11k's own hw_params table (drivers/net/wireless/ath/ath11k/core.c)
# sets `.fw.dir = "WCN6855/hw2.1"` for this exact hw_rev -- confirmed via
# GitHub's own linux-surface/aarch64-firmware repo (a real, working
# firmware distribution for this same class of ARM device) that
# `ath11k/WCN6855/hw2.1` is *literally a symlink to `hw2.0`* there --
# i.e. hw2.1 has no distinct firmware content, it just needs the hw2.0
# blobs staged under the hw2.1-named path ath11k actually requests.
# linux-firmware's own upstream repo only ships `ath11k/WCN6855/hw2.0/`
# (confirmed: no `hw2.1` tree exists there) -- so this script fetches from
# hw2.0 and stages locally under hw2.1, replicating that same real-world
# practice.
#
# WiFi calibration: since the throughput investigation (2026-09, see
# docs/wifi-samsung-calibration.md), this script defaults to staging this
# device's OWN factory calibration (vendor-firmware-dump/.../bdwlan.elf,
# wrapped by scripts/build-samsung-board2.py) plus Samsung's version-
# matched amss20.bin + m3.bin -- WIFI_CAL=samsung. The generic
# linux-firmware board-2.bin genuinely does not fit this board (one RX
# chain at the noise floor, ~6-9 Mbit/s); the factory calibration gives
# ~5x throughput. This needs the patched kernel (its
# ath11k_mac_skip_legacy_wmm_params() quirk auto-handles a NULL-deref in
# the HSP.2.0 firmware's WMM-params handler). An earlier version of this
# script deliberately did NOT do this -- an out-of-generation board-data
# file mixed with an out-of-generation amss did cause an MHI RDDM crash
# for the sibling X910 Ultra port -- but that turned out to be a
# generation *mismatch*: the version-matched Samsung triple works.
# WIFI_CAL=community restores the old upstream-only behaviour.
# `regdb.bin` (regulatory DB, not chip- or generation-specific) comes
# from this device's own dump either way -- linux-firmware ships none for
# this chip.
#
# ## Bluetooth firmware -- RESOLVED via a DTS fix, not a firmware fetch
#
# btqca.c's QCA_QCA6390 case unconditionally requests
# "qca/htbtfw<rom_ver>.tlv" + "qca/htnv<rom_ver>.bin" with **no fallback
# path** (unlike QCA_WCN6750/QCA_WCN6855, which retry a second filename on
# failure -- see qca_uart_setup() in btqca.c). Confirmed by direct listing
# of linux-firmware's own `qca/` directory *and* an exhaustive search of
# this device's real `/vendor/firmware` (mounted directly via TWRP, not
# just the earlier partial pull): no `htbtfw21.tlv`/`htnv21.bin` exists
# anywhere, upstream or on-device. The real fix, applied in
# `kernel/dts/sm8550-samsung-x716b.dts`: the BT node's `compatible` was
# corrected from `"qcom,qca6390-bt"` to `"qcom,wcn6855-bt"` (matching the
# WLAN side's own real hardware identity), which makes `btqca.c` try
# `wcnhpbtfw21.tlv`/`wcnhpnv21*` first and fall back to plain
# `hpbtfw21.tlv`/`hpnv21*` -- landing exactly on this device's genuine,
# on-device firmware (confirmed present via
# `scripts/extract-vendor-firmware.sh`). See that DTS node's own comment
# and docs/porting-log.md's Networking bring-up Session 8 entry for the
# full reasoning (including why switching `compatible` this way is safe:
# hci_qca only consults `qca_soc_data_wcn6855`'s own regulator list when
# the BT node has an `enable-gpios` property, which ours doesn't -- power
# is handled by the shared `wcn_pmu` pwrseq device instead, unaffected by
# this change). This script stages those real, proprietary
# `vendor-firmware-dump` files rather than fetching anything for BT --
# they're Samsung's own binaries, not something to source from a public
# firmware repo.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/buildroot/firmware-overlay/lib/firmware}
wifi_upstream_dir="ath11k/WCN6855/hw2.0"
wifi_dir="$outdir/ath11k/WCN6855/hw2.1"
bt_dir="$outdir/qca"
bt_vendor_dir="$repo_root/vendor-firmware-dump/firmware"
mkdir -p "$wifi_dir" "$bt_dir"

FW_BASE="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main"

# WIFI_CAL selects which WiFi calibration/firmware set to stage:
#
#   samsung  (default) -- this device's own factory calibration
#     (vendor-firmware-dump/.../bdwlan.elf) wrapped into board-2.bin by
#     scripts/build-samsung-board2.py, paired with Samsung's version-
#     matched amss20.bin + m3.bin. The generic linux-firmware board-2.bin
#     does not fit this specific board (one RX chain at the noise floor,
#     ~6-9 Mbit/s); Samsung's own calibration gives ~5x throughput, no
#     dead chain, NSS 2. Requires the patched kernel -- its
#     ath11k_mac_skip_legacy_wmm_params() quirk auto-activates on the
#     WLAN.HSP.2.0 build id to dodge an unconditional NULL-deref in that
#     firmware's WMM-params handler. Full write-up:
#     docs/wifi-samsung-calibration.md.
#
#   community -- the upstream linux-firmware WCN6855/hw2.0 blobs (what
#     this port shipped before the calibration investigation). Stable
#     everywhere, but the throughput ceiling stands. Use this if running
#     an unpatched kernel, or for an A/B comparison.
#
# regdb.bin is the same file either way (the regulatory DB is not chip-
# or generation-specific; linux-firmware ships none for this chip).
WIFI_CAL=${WIFI_CAL:-samsung}
ss_fw_dir="$repo_root/vendor-firmware-dump/firmware/qca6490"

case "$WIFI_CAL" in
community)
	echo "== WiFi: community linux-firmware set (WIFI_CAL=community) =="
	for f in amss.bin board-2.bin m3.bin; do
		echo "fetching $f from upstream hw2.0"
		curl -fsSL -o "$wifi_dir/$f.tmp" "$FW_BASE/$wifi_upstream_dir/$f"
		mv "$wifi_dir/$f.tmp" "$wifi_dir/$f"
	done
	;;
samsung)
	echo "== WiFi: Samsung factory calibration set (WIFI_CAL=samsung, default) =="
	for f in amss20.bin bdwlan.elf m3.bin; do
		[ -f "$ss_fw_dir/$f" ] || {
			echo "error: $ss_fw_dir/$f missing -- run scripts/extract-vendor-firmware.sh (device in TWRP)" >&2
			exit 1
		}
	done
	cp "$ss_fw_dir/amss20.bin" "$wifi_dir/amss.bin"
	cp "$ss_fw_dir/m3.bin"     "$wifi_dir/m3.bin"
	# board-2.bin: build from a fresh community base so the swap is
	# always against a known-good container, never a re-wrapped one.
	curl -fsSL -o "$wifi_dir/board-2.bin.community" \
		"$FW_BASE/$wifi_upstream_dir/board-2.bin"
	"${PYTHON:-python3}" "$repo_root/scripts/build-samsung-board2.py" \
		"$wifi_dir/board-2.bin.community" "$wifi_dir/board-2.bin"
	rm -f "$wifi_dir/board-2.bin.community"
	;;
*)
	echo "error: WIFI_CAL must be 'samsung' or 'community', got '$WIFI_CAL'" >&2
	exit 1
	;;
esac

vendor_regdb="$repo_root/vendor-firmware-dump/firmware/qca6490/regdb.bin"
if [ -f "$vendor_regdb" ]; then
	echo "staging regdb.bin from this device's own pulled dump (linux-firmware ships none for WCN6855/QCA6390)"
	cp "$vendor_regdb" "$wifi_dir/regdb.bin"
else
	echo "warning: $vendor_regdb not found -- regdb.bin not staged (ath11k treats it as optional)" >&2
fi

echo "== Bluetooth: staging real hp-prefixed files from vendor-firmware-dump (see header comment) =="
bt_missing=0
bt_files=(
	hpbtfw21.tlv
	hpnv21.bin hpnv21.b9a hpnv21.b9b hpnv21.baa hpnv21.bb7 hpnv21.bb9
	hpnv21g.bin hpnv21g.b9a hpnv21g.b9b hpnv21g.baa hpnv21g.bb7 hpnv21g.bb9
)
for f in "${bt_files[@]}"; do
	if [ -f "$bt_vendor_dir/$f" ]; then
		cp "$bt_vendor_dir/$f" "$bt_dir/$f"
		echo "staged $f"
	else
		echo "warning: $bt_vendor_dir/$f not found -- run scripts/extract-vendor-firmware.sh first" >&2
		bt_missing=1
	fi
done
if [ "$bt_missing" -eq 1 ]; then
	echo "== BT firmware incomplete: run scripts/extract-vendor-firmware.sh (device in TWRP) then re-run this script ==" >&2
fi

echo "== staged files =="
find "$outdir" -type f -exec ls -la {} \;
