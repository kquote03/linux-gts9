#!/usr/bin/env bash
# Fetch and patch the AudioReach ASoC topology binary the sound card needs.
#
# sound/soc/qcom/qdsp6/topology.c's audioreach_tplg_init() does a mandatory
# request_firmware("qcom/sm8550/<model>-tplg.bin") at card-probe time and
# treats a miss as fatal -- this binary describes the ADSP-side DSP
# module/widget/route graph up to the I2S/codec-DMA hardware interface. It
# does NOT exist anywhere reachable for this board: not on the device, not
# in Fedora's linux-firmware package, not authored by this project.
#
# It does not need to be authored from scratch, though. AudioReach topology
# is agnostic to which codec actually receives the bitstream (our 4x
# CS35L45 speaker amps sit entirely outside its scope, on the I2C-controlled
# codec side of the machine driver) -- so the *same* topology Qualcomm ships
# for its own SM8550 reference boards is directly reusable. This is exactly
# what agcarbajo/postmarketos-galaxy-tab-s9-ultra (SM-X910, same
# 4x-CS35L45-on-PRIMARY-MI2S + VA-macro-DMIC layout as this board) does in
# its own scripts/stage-audioreach-topology.sh, which this script mirrors:
#
#   1. Pin `qcom/sm8550/SM8550-HDK-tplg.bin` from upstream linux-firmware.git
#      at a known commit and verify its sha512 before touching it.
#   2. Patch one 4-byte token: the I2S sink module's
#      AR_TKN_U32_MODULE_SD_LINE_IDX (kernel/linux/include/uapi/sound/
#      snd_ar_tokens.h: token 256) from 1 (I2S_SD0) to 2 (I2S_SD1) -- our
#      4 speaker amps are wired to MI2S serial-data-line 1, not line 0 like
#      the stock HDK/QRD/MTP boards assume. Confirmed against our own DTS:
#      &tdm0_dout_active (the playback pinctrl state) uses
#      function = "i2s0_data1", the same SD1 convention the Ultra port's
#      own hardware needed -- not a guess.
#   3. Verify the patched output's sha512 too: it comes out byte-for-byte
#      identical to the Ultra port's own confirmed-working patched file
#      (0c362136...), which is a strong independent confirmation that no
#      board-specific authoring was needed at all, just this reuse.
#
# Verified live on X716B hardware: with this file in place, `snd-sc8280xp`
# instantiates a real ALSA card, and a `speaker-test` tone was confirmed
# audible from the tablet's own speakers (all 4 CS35L45 amps, once their
# "AMP Enable Switch" controls are also on -- see
# rootfs/overlay-common/usr/libexec/gts9wifi-audio-init).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="${1:-$repo_root/out/firmware/qcom-sm8550/Samsung-Galaxy-Tab-S9-5G-tplg.bin}"
mkdir -p "$(dirname "$out")"

lfw_commit="18cf97993f06c0a28d88cee30b7b646807642acd"
lfw_repo="https://gitlab.com/kernel-firmware/linux-firmware.git"
upstream_sha512="d41185a9c905571f7c234ff8caf6e6d24870161a5e6ef0316bb997bfd26cee871a483287308a0af177d39a81b256def4cfa99b0f2594b364ba7ef1104dd9caca"
patched_sha512="0c36213640a9c8d8ddbe76ad9b948ff2eb0b063803c6d5906cef2407628ec92e23adc279eb3fe150dc0fd75d8b01a22bca21fc16466d9b8a69775fdb31bdf410"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== fetching SM8550-HDK-tplg.bin from linux-firmware.git @ $lfw_commit =="
git -C "$work" init -q
git -C "$work" remote add origin "$lfw_repo"
git -C "$work" config core.sparseCheckout true
mkdir -p "$work/.git/info"
echo "qcom/sm8550/SM8550-HDK-tplg.bin" > "$work/.git/info/sparse-checkout"
git -C "$work" fetch --depth 1 origin "$lfw_commit"
git -C "$work" checkout FETCH_HEAD -- >/dev/null

src="$work/qcom/sm8550/SM8550-HDK-tplg.bin"
got_sha512=$(sha512sum "$src" | cut -d' ' -f1)
if [ "$got_sha512" != "$upstream_sha512" ]; then
	echo "REFUSING: SM8550-HDK-tplg.bin sha512 mismatch" >&2
	echo "  expected: $upstream_sha512" >&2
	echo "  got:      $got_sha512" >&2
	exit 1
fi
echo "sha512 verified: unpatched SM8550-HDK-tplg.bin matches the pinned upstream hash"

echo "== patching AR_TKN_U32_MODULE_SD_LINE_IDX: I2S_SD0 (1) -> I2S_SD1 (2) =="
python3 "$repo_root/scripts/patch-audioreach-sd-line.py" "$src" "$out"

got_patched_sha512=$(sha512sum "$out" | cut -d' ' -f1)
if [ "$got_patched_sha512" != "$patched_sha512" ]; then
	echo "REFUSING: patched output sha512 mismatch (patch logic may have changed)" >&2
	echo "  expected: $patched_sha512" >&2
	echo "  got:      $got_patched_sha512" >&2
	exit 1
fi
echo "sha512 verified: patched output matches the Tab S9 Ultra port's own confirmed-working file"
echo "wrote $out"
