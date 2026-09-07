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
# Deliberately does NOT reuse this device's own pulled downstream firmware
# (vendor-firmware-dump/firmware/qca6490/{amss20.bin,bdwlan*.elf,...}) for
# the main WiFi image/board-data: the sibling X910 Ultra port's own
# bring-up hit exactly this trap for its (different) WCN7850 chip --
# mixing a downstream-generation board-data file with an official
# upstream amss caused an MHI RDDM crash. Samsung's own `bdwlan*.elf`
# board-data files are almost certainly in a downstream-specific format,
# not directly usable by ath11k's board-2.bin/board.bin loader. Instead,
# this fetches the well-tested official linux-firmware blobs. Only
# `regdb.bin` (the regulatory database, not chip- or generation-specific)
# is reused from this device's own pulled dump, since linux-firmware's own
# WCN6855/hw2.0 directory doesn't ship one at all.
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

echo "== WiFi: ath11k/WCN6855/hw2.1 (staged from upstream's hw2.0 content -- hw2.1 is a symlink to hw2.0 in real-world firmware distros) =="
for f in amss.bin board-2.bin m3.bin; do
	if [ ! -f "$wifi_dir/$f" ]; then
		echo "fetching $f"
		curl -fsSL -o "$wifi_dir/$f.tmp" "$FW_BASE/$wifi_upstream_dir/$f"
		mv "$wifi_dir/$f.tmp" "$wifi_dir/$f"
	fi
done

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
