# Hardware facts — Samsung Galaxy Tab S9 5G (SM-X716B)

Ground-truth reference for this project. Every fact below is tagged with a
confidence level:

- **measured** — verified directly against this exact physical tablet or a
  backup taken from it.
- **inherited** — taken from the `ubuntu-galaxy-tab-s9ultra` reference port
  for the sibling SM-X910, not yet re-verified on X716 hardware. Treat as a
  hypothesis, not a fact, until confirmed.
- **assumed** — a reasonable guess with no direct verification either way.

Update this file as facts are confirmed or invalidated — later phases should
cite this document instead of re-deriving these details.

## Device identity

- Model: `SM-X716B`, chipset Qualcomm Snapdragon 8 Gen 2 (SM8550, codename
  "kalama"), Adreno 740 GPU. **measured** (`ro.product.model`, DTS compatible
  strings in stock kernel source).
- Stock OS: Android 15, build `AP3A.240905.015.A2X716BXXU5CYD9`. **measured**
  (`ro.build.fingerprint`).
- Stock kernel: Linux 5.15.153, GKI `android13-8` branch, Google ACK + Qualcomm
  msm-kernel downstream. **measured** (kernel version string in `boot.emmc.win`
  and `/proc/version` on-device).
- Devicetree model string: `"Samsung GTS9 PROJECT (board-id,04)"`. **measured**
  (`/proc/device-tree/model` while booted to stock Android — board-id 04 is
  this specific unit's board revision).

## Bootloader / verified boot state

- `ro.boot.flash.locked=0`, `ro.boot.verifiedbootstate=orange`,
  `ro.boot.warranty_bit=1` — bootloader unlocked. **measured**.
- `ro.secure=1`, `ro.debuggable=0` — production build, but rooted via Magisk
  (`su` returns `context=u:r:magisk:s0`). **measured**.
- `fastboot` is present as a host tool but is **not a usable flashing path**
  on this device family — Samsung devices use Download Mode/Odin instead.
  Flashing for this project goes through TWRP + `dd` to raw block devices.
  **inherited** (confirmed true for X910; not yet independently tested on
  X716, but consistent with Samsung's standard behavior across the line).
- **vbmeta already has AVB flags=2 (verification disabled).** Confirmed by
  manually parsing the AVB header at `/dev/block/by-name/vbmeta`
  (`/dev/block/sde15`): magic `"AVB0"` at offset 0, `flags` field (u32,
  big-endian) at offset `0x78` = `0x00000002`, and the `avbtool 1.1.0` release
  string lands exactly at the expected offset `0x80`, confirming the header
  layout was parsed correctly. **measured**. This means a custom-signed (or
  unsigned) boot chain should already be accepted without needing to touch
  vbmeta — a major risk reduction versus the X910 reference, which needed to
  actively ensure this state.
- No A/B slots on this device. **measured** (by-name partition map has single
  `boot`/`vendor_boot`/etc., no `_a`/`_b` suffixes).

## Partition table (by-name, from stock Android boot, root shell)

All on the main UFS LU (`sda`, ~124,141,568 KiB ≈ 118.4 GB) unless noted.

| Name | Device | Size (measured, blocks or bytes) | Confidence |
|---|---|---|---|
| `boot` | sda21 | 100,663,296 B | measured (backup + live partition) |
| `init_boot` | sda22 | 8,388,608 B | measured |
| `vendor_boot` | sda24 | 100,663,296 B | measured |
| `dtbo` | sda30 | 16,777,216 B | measured |
| `recovery` | sda23 | 107,008 KiB | measured |
| `super` (dynamic: system/vendor/product/etc.) | sda25 | 11,370,496 KiB ≈ 10.8 GB | measured |
| `userdata`/`/data` | sda34 | 110,041,052 KiB ≈ 107.5 GB, **93% full, 7.9 GB free** | measured |
| `modem` | sda20 | 197,132,288 B, FAT16 container (Samsung CP RAM-dump format) | measured (from TWRP backup) |
| `vbmeta` | **sde15** (separate LUN from `sda`) | 131,072 B | measured |

Summing all `sda` partition sizes accounts for all but ~1 MiB of the disk
(GPT header/backup overhead) — **there is no free unallocated space on the
main LU**. Any internal-storage rootfs plan requires shrinking an existing
partition; this is explicitly deferred (see README non-goals).

microSD card: `/dev/block/mmcblk1` → `mmcblk1p1`, exFAT, label `External`,
~238 GB (249,872,384 KiB), mounted at `/storage/79F9-FD08` when Android is
booted. **measured**. This is the MVP rootfs target (Phase 4).

## Boot image formats (parsed from the 2026-09-04 TWRP backup)

- `boot.emmc.win`: Android boot image header **v4**, magic `"ANDROID!"`,
  `header_size=0x630`, page size 4096 (implicit for v3/v4), `kernel_size=
  0x02b31a00` (~43.2 MiB), `ramdisk_size=0`. Kernel string: `Linux version
  5.15.153-android13-8-ab`. **measured**.
- `init_boot.emmc.win`: header v4, `kernel_size=0`, `ramdisk_size=0x0016aed3`
  (~1.42 MiB) — GKI 2.0 generic-ramdisk-only image. **measured**.
- `vendor_boot.emmc.win`: magic `"VNDRBOOT"`, header v4, `page_size=4096`,
  `kernel_addr=0x00008000`, `ramdisk_addr=0x02000000`,
  `vendor_ramdisk_size≈12.75 MiB`. Vendor cmdline captured verbatim:
  ```
  video=vfb:640x400,bpp=32,memsize=3072000 printk.devkmsg=on
  firmware_class.path=/vendor/firmware_mnt/image bootconfig loop.max_part=7
  ```
  **measured**.
- `dtbo.emmc.win`: DTBO magic `0xd7b7ab1e`, `header_size=32`,
  `dt_entry_size=32`, `dt_entries_offset=32`, `page_size=4096`,
  `dt_entry_count=4` — four ~805 KB DT overlay blobs, tightly packed, total
  real data ~3.07 MiB of the 16 MiB partition. `id`/`rev` fields all 0 (board
  selection is presumably driven by ABL board-detection, not DTBO id
  matching). **measured**.
- All four images (`boot`/`init_boot`/`vendor_boot`/`dtbo`) carry a real
  64-byte AVB hash footer (`AVBf` magic) at `size - 64`. **measured**.

## Devicetree facts (from `android_kernel_samsung_gts9` stock source)

- `qcom,msm-id = <0x207 0x10000 0x218 0x10000 0x207 0x20000 0x218 0x20000>;`
  — **identical across all four board-revision DTS files**
  (`gts9_eur_openx_w00_r0{0,1,2,4}.dts`). `0x207`=519=SM8550, `0x218`=536=
  SM8550-P (premium bin). **measured** (grepped directly, all 4 files).
- `qcom,board-id = <0x10008 NN>;` where `NN` = `0x00`/`0x01`/`0x02`/`0x04`
  for `_r00`/`_r01`/`_r02`/`_r04` respectively — this tablet reports board-id
  `04` live (`/proc/device-tree/model`). **measured**.
- `sec_log_buf_region@880200000` — 2 MiB persistent log carveout
  (`reg = <0x08 0x80200000 0x00 0x200000>`), also referenced via
  `ramoops_mem = "/fragment@104:target:0"`. Confirmed present in the X716
  downstream DTS. **measured**. This is the planned console-less debug
  channel: TWRP is a known consumer of this same region for
  `/proc/last_kmsg`-style readback after a hang/panic — **inherited**
  assumption from the X910 reference that this readback mechanism actually
  works on X716; must be validated with the *stock* kernel first (Phase 2)
  before relying on it to debug a mainline kernel.
- Console UART candidate: `qup_hsuart@a9c000` (GENI QUPv3_1 SE,
  `hsuart5` alias). **measured** (present in stock DTS), but its use as a
  *console* (vs. its stock role, likely Bluetooth HCI) is **assumed** — needs
  verification. No UART cable is available to confirm output regardless.
- UFS host controller supplies: `vcc-supply` → `pm_humu_l17`,
  `vccq-supply`/`qcom,vccq-shutdown-supply` → `pm_v6g_l1`. **measured**
  (resolved via the DTS's `__symbols__`/fragment overlay table). These are
  **different rail names from the X910 reference** (`vreg_l17b_2p5`,
  `vreg_l1g_1p2`) — same PM8550-family silicon, different board wiring/
  naming; must not be copied from the X910 DTS.
- Panel: `samsung,disp-model = "AMSA10FA01"` — **different from X910's**
  `"AMSA46AS02"`/ANA38407. No mainline driver exists for this panel.
  **measured**, deferred to future work.
- Touchscreen: `compatible = "stm,fts_touch"` (STMicroelectronics) —
  **different from X910's** Goodix `gt9916`. No board-specific mainline
  driver exists yet; mainline has a generic `drivers/input/touchscreen/st/fts`
  as a possible starting point. **measured**, deferred to future work.
- Radio: this is the 5G SKU (unlike the Wi-Fi-only X910 reference) — has a
  `modem` partition (188 MiB, FAT16 container). Permanently out of scope; no
  mainline story exists for Samsung's Shannon modem IPC on this platform.

## Toolchain

- Stock kernel's own `shell.nix` builds successfully with `llvmPackages_18`
  from nixpkgs (used to supply a modern Clang/lld for the GKI kernel's own
  Kleaf/Bazel build, replacing Samsung's prebuilt `clang-r450784e`).
  **measured** (read directly from `android_kernel_samsung_gts9/shell.nix`).
  Confirms a modern-enough Clang (≥17, needed for the mainline kernel target)
  is readily available via nix on this dev machine.
- This project's `shell.nix` (repo root) uses `llvmPackages_19` (Clang 19.1.7,
  confirmed available in the local nixpkgs snapshot `26.05pre-git`) plus an
  `aarch64-unknown-linux-gnu` GNU cross toolchain (GCC 15.2.0, via
  `pkgsCross.aarch64-multiplatform.stdenv.cc`) for uniLoader's
  `CROSS_COMPILE=` build path. `mmdebstrap` is **not packaged** in this
  nixpkgs snapshot (confirmed via `nix eval nixpkgs#mmdebstrap` — no such
  attribute); `debootstrap` is used instead. `kpartx` is provided by the
  `multipath-tools` package (confirmed: builds, `bin/kpartx` present), not a
  standalone `kpartx` attribute (also confirmed absent). **measured** — every
  tool in `shell.nix` was verified to actually run inside the shell, not just
  that the derivation evaluates.

## Pinned upstream sources

- **uniLoader**: `https://github.com/ivoszbg/uniLoader`, pinned commit
  `2418e06635e931e31c74833b8809415fa9695b79` (2026-08-24, "board: Add support
  for HTC Desire 628 Dual (v36bml_dugl)"), fetched via
  `scripts/fetch-uniloader.sh` into `uniloader/upstream/` (gitignored).
  **measured** (`git ls-remote` + `git rev-parse HEAD` after fetch).
- **mkbootimg**: `https://android.googlesource.com/platform/system/tools/mkbootimg`,
  pinned commit `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` (2025-03-02),
  vendored (not fetched at build time) into `third_party/android-tools/mkbootimg/`
  — see that directory's `PROVENANCE.md`.
- **avb**: `https://android.googlesource.com/platform/external/avb`, pinned
  commit `c5066a96caa7bf4150c0a8cc8cc14ab81733fdc7` (2026-08-19), vendored
  into `third_party/android-tools/avb/` — see that directory's `PROVENANCE.md`.
- Mainline Linux kernel: **not yet pinned** — Phase 1 step 1
  (`scripts/fetch-mainline.sh`) has not run yet.

## Open risks / unverified assumptions (carried into later phases)

1. Whether X716's ABL has the same DTB-append-to-kernel /
   DTBO-fallback-to-inert-stub behavior the X910 reference relies on.
   **Unverified** — first flash attempt (Phase 2) is the real test.
2. Whether ABL reads the boot DTB from `vendor_boot` or from `boot`
   (appended to `Image.gz`) — assumed to match X910 by analogy, must be
   confirmed on X716 specifically before trusting DTS-only iteration to
   "just work" by reflashing `vendor_boot`.
3. Whether the 5G SKU's ABL has board-id/partition-selection differences
   from the Wi-Fi-only X910 (e.g. due to the modem partition's presence).
   **Unknown** until first flash.
4. Whether the `sec_log_buf_region` readback-via-TWRP debug channel actually
   works on this unit — needs a stock-kernel validation pass first.
