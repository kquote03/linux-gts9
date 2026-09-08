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

echo "== mounting apnhlos (vfat/FAT16, adsp.mdt+segments) and dsp (ext4, HexagonFS payload) =="
# gts9wifi-fedora pivot: their own docs/PORT-KIT.md documents these as the
# real source of the ADSP firmware/HexagonFS payload ("extracted from the
# tablet's own stock partitions (apnhlos, dsp, persist)") -- confirmed
# directly on this X716B unit rather than assumed:
#  - apnhlos (this device: /dev/block/sda17) is FAT16 ("MSDOS5.0" boot
#    sector, confirmed via hexdump), NOT ext4 like the other partitions
#    this script already mounts -- holds the actual PIL-loadable firmware
#    images under image/: adsp.mdt + adsp.b00..b50 (real QUALCOMM DSP6 ELF,
#    confirmed via `file`) + adsp_dtb.mdt + adsp_dtb.b00..b02. Also
#    cdsp.{mdt,b*,_dtb.*} alongside -- deliberately NOT pulled (CDSP/
#    cellular stays out of scope, see docs/hardware-facts.md non-goals).
#  - Also under image/: adspr.jsn, adsps.jsn, adspua.jsn, cdspr.jsn -- the
#    QMI servreg (PDR) service-registry maps for root_pd/sensor_pd/audio_pd
#    and cdsp's root_pd (Samsung ships none for charger_pd, which is why
#    battery goes through the SM5714 directly from the AP -- see the DTS
#    comment on &i2c_hub_8). Real, live-hardware-confirmed root cause for
#    why pd-mapper failed with "no pd maps available" and the sound card
#    never got past "error getting cpu dai name": pd-mapper's
#    pd_enumerate_jsons() scans the *same directory* the currently-loaded
#    remoteproc firmware came from (dirname of
#    /sys/class/remoteproc/remoteproc0/firmware, i.e. /lib/firmware/qcom/
#    sm8550/) for *.jsn/*.jsn.xz files -- without adspua.jsn (which maps
#    avs/audio -> msm/adsp/audio_pd) there, pd-mapper's pd_maps stays empty
#    and it exits(1) immediately, so the kernel's PDR client can never get
#    an UP indication for audio_pd, so q6apm's platform device (the sound
#    card's cpu dai, "q6apmbedai") never registers. Pulling these 4 files
#    into firmware/qcom-sm8550/ alongside adsp.mdt (same destination the
#    rootfs build stages into /usr/lib/firmware/qcom/sm8550/) fixes this
#    -- confirmed live: copying them in and restarting pd-mapper made
#    q6apm register immediately (gprsvc:service:2:1/2:2 appeared on
#    aprbus, "error getting cpu dai name" left devices_deferred).
#  - dsp (this device: /dev/block/sda16) is ext4, holds userspace-side
#    Hexagon FastRPC skel libraries under adsp/ (audio codec modules,
#    "libsns_*" sensor skel libs -- SSC's real userspace half) and cdsp/
#    (not pulled, same reasoning as above). This is the real, on-device
#    source for what gts9wifi-fedora's own hexagonrpcd-samsung.spec calls
#    the "firmware-samsung-gts9wifi payload" / HexagonFS root
#    (/usr/share/qcom/sm8550/Samsung/gts9wifi/dsp) -- X716B needs its own
#    extraction here, not a reuse of theirs (device-specific signed blobs).
adb shell "mkdir -p /mnt_apnhlos /mnt_dsp
mount -t vfat -o ro /dev/block/bootdevice/by-name/apnhlos /mnt_apnhlos 2>/dev/null
mount -t ext4 -o ro /dev/block/bootdevice/by-name/dsp /mnt_dsp 2>/dev/null"
mkdir -p "$outdir/firmware/qcom-sm8550" "$outdir/hexagonfs/dsp/adsp"
echo "-- adsp PIL firmware (apnhlos/image) --"
adb shell "ls /mnt_apnhlos/image/adsp.mdt /mnt_apnhlos/image/adsp.b* \
	/mnt_apnhlos/image/adsp_dtb.mdt /mnt_apnhlos/image/adsp_dtb.b* \
	/mnt_apnhlos/image/adspr.jsn /mnt_apnhlos/image/adsps.jsn \
	/mnt_apnhlos/image/adspua.jsn /mnt_apnhlos/image/cdspr.jsn 2>/dev/null" \
	| tr -d '\r' | while IFS= read -r remote; do
	[ -z "$remote" ] && continue
	adb pull "$remote" "$outdir/firmware/qcom-sm8550/" >/dev/null
done
echo "pulled $(ls "$outdir/firmware/qcom-sm8550" | wc -l) adsp PIL firmware + PDR registry files"
echo "-- HexagonFS payload (dsp/adsp) --"
adb pull /mnt_dsp/adsp "$outdir/hexagonfs/dsp/" 2>&1 | tail -3
adb shell "umount /mnt_apnhlos /mnt_dsp 2>/dev/null; rmdir /mnt_apnhlos /mnt_dsp 2>/dev/null" || true

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

echo "== staging AudioReach topology (not device-specific -- reused + patched, see stage-audioreach-topology.sh) =="
# Not actually pulled off this device (it doesn't exist on any Samsung
# partition -- see that script's own header), but it belongs in this same
# staging directory: every rootfs builder that copies
# vendor-firmware-dump/firmware/qcom-sm8550/* into its own /lib/firmware
# should get this file the same way it gets adsp.mdt and the PDR .jsn
# files, without needing separate awareness of where it came from.
tplg_dir="$outdir/firmware/qcom-sm8550"
mkdir -p "$tplg_dir"
if [ ! -f "$tplg_dir/Samsung-Galaxy-Tab-S9-5G-tplg.bin" ]; then
	"$(dirname "${BASH_SOURCE[0]}")/stage-audioreach-topology.sh" \
		"$tplg_dir/Samsung-Galaxy-Tab-S9-5G-tplg.bin" \
		|| echo "warning: AudioReach topology staging failed -- sound card will not instantiate (re-run scripts/stage-audioreach-topology.sh manually to see why)" >&2
fi

echo "== done -- staged under $outdir (gitignored, proprietary) =="
find "$outdir" -type f | sort
