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

## Last verified rollback point

Fresh `boot`/`init_boot`/`vendor_boot`/`dtbo` backup taken directly via
TWRP `dd` (not TWRP's own nandroid UI) on 2026-09-05, immediately before
the first custom flash attempt. Pulled off-device and hash-verified to
match the on-device dump exactly before the on-device tmpfs copy was
deleted. Stored at `backups/2026-09-05/` (gitignored — binary artifacts
aren't committed).

| Partition | Size (bytes) | sha256 |
|---|---|---|
| `boot` | 100,663,296 | `a8cd8194a3b5e091ffcc25f26785eafe3aef44af5dee05e02074abbc5ca71874` |
| `init_boot` | 8,388,608 | `2c5311c7f64dc474697ac9ef0ae2c199830fe2679f5a3774fa017b9f67af7bc3` |
| `vendor_boot` | 100,663,296 | `2deb5fe49d2af14023a02bf36efa0c51faf7ce875f43321bcf000aa6adc35ae4` |
| `dtbo` | 16,777,216 | `d86cd898016ef2c1819532f22904ba3ae542b1fb99795edfeb1d6f376fb3768d` |

All four sizes match this device's confirmed stock partition sizes exactly
(see the partition table below) — no surprises going into the first flash.

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
  `"AMSA46AS02"`/ANA38407 (same DDIC family, different physical part). No
  mainline driver existed for this panel; one was written from scratch for
  Session 5 (`kernel/drivers/panel-samsung-ana38407-x716.c`), forked from
  the X910 Ultra port's own ANA38407-family driver but with the actual DCS
  init/exit byte sequences re-derived from this panel's own downstream
  source rather than assumed transferable. **measured and confirmed
  working on real hardware** (Session 5, same day): panel lights up, DPU/
  DSI/panel driver bind cleanly with zero errors, panel ID reads back
  `80 00 04` matching ABL's own independently-read `lcd_id=800004` for
  this exact unit — see `docs/porting-log.md`'s "Real-hardware validation"
  entry for the full `dmesg` evidence.
  - Reset GPIO 125, TE GPIO 86 — cross-confirmed two ways: X716's own
    stock DTS (`qcom,platform-reset-gpio`/`qcom,platform-te-gpio`) *and*
    independently matching the exact same GPIO numbers the X910 Ultra
    port uses for its own (different-part) ANA38407-family panel.
  - Resolution 2560×1600, DSC 1.1, 2 slices 1280×100, 8bpc/8bpp — decoded
    byte-for-byte from the panel's own 88-byte PPS payload in Samsung's
    downstream panel data file, cross-checked against the stock DTS's
    display-timings block (both agree exactly).
  - Physical size 236mm×148mm (`qcom,mdss-pan-physical-{width,height}-dimension`).
  - Panel supply rails vddio (1.8V)/vdd (1.2V)/vci (3.0V) — voltages
    measured from the stock DTS's `dsi_panel_pwr_supply` table; which
    RPMh LDO *index* they're actually wired to is **not independently
    measured**, only copied by analogy from the X910 Ultra port's own
    panel rails (same SoC generation) — see the DTS comment above these
    regulators for the exact caveat. **Confirmed working in practice**
    (Session 5, same day): the panel powers on and responds correctly
    with these rails as wired, real-hardware evidence the analogy held.
  - AVDD (~5.5V AMOLED ELVDD, GPIO load switch): was **the least confident
    value in the whole display subtree** — the stock DTS's decompiled form
    lost the resolved GPIO for this regulator (proxy-supply/phandle
    indirection that didn't survive decompilation, the same class of gap
    already seen with the UFS PHY rails). GPIO 187 was a first guess
    (reused from the stock tree's differently-named `panel_ldo_en` fixed
    regulator). **Confirmed good enough in practice** (Session 5, same
    day): the panel powers on and the ID reads back correctly with this
    wiring — not independently proven this is the *exact* real AVDD GPIO
    (a wrong-but-harmless GPIO, or one already high from boot, could in
    principle produce the same result), but no evidence it's wrong either.
  - Optical/under-display fingerprint: the stock DTS node *does* carry
    `samsung,support-optical-fingerprint` and real vsync-relative HBM
    timing code in the common downstream driver — but the Tab S9 series
    ships a side-mounted capacitive fingerprint sensor (a separate SPI
    device, see the `gpio-reserved-ranges` comment in
    `kernel/dts/sm8550-samsung-x716b.dts`), so this flag is presumed inert
    boilerplate inherited from a phone panel definition; deliberately not
    ported into the new driver. **assumed** (a reasonable inference from
    the tablet's known hardware, not independently disproven).
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

## Mainline reference: an existing Samsung SM8550 board already exists upstream

Discovered while starting Phase 1 (checking kernel tag `v7.2` for SM8550 DT
support): `arch/arm64/boot/dts/qcom/sm8550-samsung-q5q.dts` in mainline Linux
is a **real, accepted, working devicetree for the Samsung Galaxy Z Fold5**
(`compatible = "samsung,q5q", "qcom,sm8550"`) — a second real-world Samsung
SM8550 device, independent of the X910 Ultra reference, and unlike it this
one is genuinely upstream (`BSD-3-Clause`, Linaro + community authors). Used
alongside the X716 downstream tree and the X910 reference as a third
cross-check. Notable, directly load-bearing findings:

- **Console UART confirmed, not just inherited.** `sm8550.dtsi` defines
  `uart7: serial@a9c000` — the exact same MMIO address as X716 downstream's
  `qup_hsuart@a9c000` (`hsuart5` alias). The Z Fold5 also uses `serial0 =
  &uart7` as its console. This resolves what was previously an "assumed"
  console-node identification to **measured/cross-confirmed** — `&uart7` is
  the console node for `kernel/dts/sm8550-samsung-x716b.dts`.
- **UFS regulators confirmed via a second independent device.** The Z Fold5
  uses `vcc-supply = <&vreg_l17b_2p5>; vccq-supply = <&vreg_l1g_1p2>;` on
  `&ufs_mem_hc` — the **same rail index numbers** (l17, l1) as X716
  downstream's `pm_humu_l17`/`pm_v6g_l1` and the X910 Ultra reference's
  identical `vreg_l17b_2p5`/`vreg_l1g_1p2`. Three independent Samsung SM8550
  devices agree on l17/l1 for UFS vcc/vccq — high confidence this is the
  Qualcomm reference-design assignment that Samsung boards inherit, not
  something to re-derive. X716's downstream label prefixes (`pm_humu_`,
  `pm_v6g_`) are almost certainly just Samsung's internal PMIC-die codenames
  for the same physical rails mainline calls `l17b`/`l1g` — use the mainline
  names (`vreg_l17b_2p5`, `vreg_l1g_1p2`) directly.
- **`sm8550.dtsi` already ships a full, correct `reserved-memory` tree** for
  the standard Qualcomm kalama reference design (hyp, xbl, aop, smem, adsp,
  mpss/modem, spss, camera, video, cdsp — all in the sub-4GB range, e.g.
  `mpss_mem` at `0x8a800000`). This is presumably the same physical layout
  Samsung's downstream tree builds on top of. **Board DTS work does not need
  to hand-copy this whole tree from the X716 downstream source** — only add
  Samsung-specific extras on top. The `sec_log_buf_region@880200000` carveout
  (address `0x8_80200000`, i.e. high 32 bits = `0x8`) sits far outside every
  address `sm8550.dtsi` reserves (all under `0x1_00000000`) — no conflict, in
  a distinct high-memory DRAM region.
- The Z Fold5 DTS `/delete-node/`s `&adspslpi_mem`, `&cdsp_mem`,
  `&mpss_dsm_mem`, `&mpss_mem`, `&rmtfs_mem` — i.e. its mainline port doesn't
  support cellular or ADSP/CDSP remoteproc firmware loading either, matching
  this project's own non-goals. Following the same deletion pattern for
  `kernel/dts/sm8550-samsung-x716b.dts` avoids declaring remoteproc nodes
  that would otherwise attempt to probe/load firmware we don't have and
  potentially hang — a concrete, precedented way to reduce Phase 2/3 risk.
- The Z Fold5 DTS wires a `simple-framebuffer` node continuing from an
  address ABL's own splash screen already set up (`chosen/framebuffer@...`,
  format `a8r8g8b8`) — a way to get *some* display output without a real
  mainline panel driver. Not pursued for the X716 MVP (display is explicitly
  deferred), but worth revisiting in future work given no mainline
  `AMSA10FA01` panel driver exists.

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
- **Mainline Linux kernel**: `https://github.com/torvalds/linux.git`, pinned
  tag `v7.2` (full stable release, newer than the X910 reference's
  `v7.2-rc3` pin), commit `8d3ae59288f1e7d58d76558a6ee96d533bc5019f`, fetched
  via `scripts/fetch-mainline.sh` into `kernel/linux/` (gitignored).
  **measured** — confirmed `sm8550.dtsi`/`pm8550.dtsi`/`pm8550vs.dtsi`/
  `pmk8550.dtsi` all present at this tag before pinning, and
  `kernel/dts/sm8550-samsung-x716b.dts` compiles cleanly against it
  (`cpp`+`dtc`, zero errors, produces a 115,635-byte DTB with `uart7`/UFS
  host/UFS PHY all resolving to `status = "okay"` with regulator phandles
  correctly resolved).

## Phase 1 build artifacts (all builds succeeded; nothing flashed yet)

Superseded by the sec-log driver addition below (kept for the record; the
"current" row in each case is what a fresh build now produces):

- Kernel `Image` (uncompressed, 42,002,944 B): now sha256
  `33d034040df4d113c42c0ebec8f09d6e5c4a5bd7f6a6356d45fdee9c5d0a1dcd`
  (previously `df61df1ce9...` before `CONFIG_X716_SEC_LOG` was added),
  release string `7.2.0-dirty` (the `-dirty` suffix is expected — our board
  DTS + Makefile line are installed into the working tree, not committed to
  `kernel/linux/`, which is gitignored).
- Board DTB (`sm8550-samsung-x716b.dtb`, 115,719 B): now sha256
  `1a58401f9011326c020641b222b7434427092afa06878176d440d1879f123cdc`
  (previously 115,635 B / `23dbee66...` before the `log-buf` consumer node
  was added) — identical output whether built standalone via `cpp`+`dtc` or
  via the full kernel build, a useful cross-check that the build
  integration didn't silently change anything.
- uniLoader binary (43,536,384 B — kernel Image + DTB + bring-up ramdisk +
  uniLoader's own code, all embedded in one flat file): now sha256
  `60964b66d25193e25960897010f8d401c81705713b6b5c93d6dcb73765b776b9`
  (previously `4397750d...`). A gzip-compressed variant (`uniLoader.gz`,
  16,334,271 B, sha256
  `86876e3534a7b15a614326a98f3f90b52eb930374a25ab04b66958f4a04c1d1e`) is
  also produced by uniLoader's own default `CONFIG_COMPRESS_GZIP=y` —
  **which of the two to package as the `boot` partition's kernel slot in
  Phase 2 is an open question** (mainline `Image.gz` is a common
  ABL-compatible convention, which favors the compressed variant, but this
  needs to be decided/tested in Phase 2, not assumed here).
- Bring-up ramdisk (`bringup-ramdisk.cpio.gz`, 851,804 B), sha256
  `053a971233cbc0824700a5b479ada5c1c92d5b92ed432c14f5a0a49d5b3397f5` — static
  aarch64 busybox + an `/init` that prints a proof-of-life line then loops
  forever. Unchanged by the sec-log driver addition.

## sec-log driver (`kernel/drivers/samsung-x716-sec-log.c`)

Primary Phase 2/3 console-less debug channel. Confirmed by reading (not
copying) Samsung's actual downstream driver source
(`drivers/samsung/debug/log_buf/{sec_log_buf_main.c,sec_log_buf.h}` in
`android_kernel_samsung_gts9`) rather than guessing the format:

- On-disk header: `struct { u32 boot_cnt; u32 magic; u32 idx; u32
  prev_idx; char buf[]; }`, magic `0x4d474f4c` ("LOGM"). **measured**
  (read directly from Samsung's GPL source).
- Devicetree wiring: a **separate consumer node** with
  `compatible = "samsung,kernel_log_buf"` and a `memory-region` phandle to
  the carveout — not the reserved-memory node itself. **measured**, and
  now added to `kernel/dts/sm8550-samsung-x716b.dts` as `log-buf`.
- Write algorithm: modulo-wrapping ring buffer over `buf[]` (size = region
  size minus header), `idx` monotonically increasing across boots (never
  reset except on first-ever init when the magic is invalid). **measured**
  from `__log_buf_write()`. TWRP's own recovery kernel is presumed to
  already contain Samsung's stock reader for this same format (it's a
  Samsung-derived recovery build) — **not independently confirmed that
  TWRP on this specific unit actually does this**, which is exactly why
  `docs/boot-strategy.md` calls for validating the capture path with the
  *stock* kernel before relying on it to debug a mainline one.
- Our driver probes as a normal `of_platform` device (roughly
  `arch_initcall` time) — **known limitation, not a confirmed-safe
  assumption**: if a hang happens earlier than that (plausible, given the
  UFS/regulator/pinctrl probe-hang risk this project already anticipates),
  this channel captures nothing. An earlycon-based capture would be the
  fallback if this proves insufficient in practice.

**End-to-end validation, done directly on this tablet (2026-09-05, read-only
— no flashing):**

1. On stock Android (currently booted, root via Magisk): `/proc/last_kmsg`
   exists, `-r--r----- 1 system log`, **exactly 2,097,136 bytes** — this
   equals `0x200000 (region size) − 16 (header size)` precisely, an exact
   independent confirmation that our driver's `rmem->size -
   offsetof(struct sec_log_buf_head, buf)` size calculation is correct.
   Content was real early-boot kernel log text from the previous boot.
2. `adb reboot recovery` → TWRP came up (`product:twrp_gts9`,
   `model:SM_X716B`). **`/proc/last_kmsg` exists there too, same exact size
   (2,097,136 bytes)**, and its content was stock Android's *late*-session
   log (service restarts, ~13.8h uptime) — i.e. **TWRP successfully read
   back sec_log_buf content written by a completely different kernel
   (stock Android) from the immediately preceding boot.** This is the
   actual mechanism this project's whole console-less debug strategy
   depends on, and it now has direct positive evidence on this exact unit,
   not just an assumption inherited from the X910 reference.
3. `adb reboot` back to stock Android — came up normally.

**This resolves the "sec-log capture path" item from the open-risks list
below** (previously listed as needing stock-kernel validation before
trusting it to debug a mainline kernel) — it's now **measured, confirmed
working**, not assumed. What remains open is only whether *our own* driver
(probing later, at `arch_initcall`, versus whatever point Samsung's stock
driver initializes) reaches that point before a mainline boot might hang —
see the limitation noted just above.

## Toolchain gotchas found while getting Phase 1 to actually build

All confirmed by reproducing the failure in isolation and testing the fix
directly, not guessed. Baked into `shell.nix`/the build scripts; recorded
here so a future session doesn't have to rediscover them:

1. Kbuild's `LLVM=1` (and uniLoader's own copy of the same kbuild-derived
   host-tool machinery) points `HOSTCC`/`HOSTCXX` at bare
   `clang-unwrapped`, which has no default header search paths on NixOS
   ("`sys/types.h` file not found" building `scripts/basic/fixdep`). Only a
   **command-line-supplied** `HOSTCC=cc HOSTCXX=c++` fixes it —
   environment-exported values alone are not honored, for both the kernel
   build and uniLoader's build.
2. Bare `clang-unwrapped` also doesn't auto-find its own resource-dir
   (builtin headers like `arm_neon.h`) on NixOS — nixpkgs splits it into a
   separate `.lib` output. Needs `-resource-dir=<path>` **and** an explicit
   `-isystem <path>/include` (the kernel's `-nostdinc` flag drops
   resource-dir from the search path entirely, not just normal system
   dirs) via `KCFLAGS`, again only effective when passed on the `make`
   command line, not merely exported.
3. `qemu_full` in nixpkgs pulls in a large unrelated dependency tree
   (ceph/arrow/glusterfs/azure-sdk); `qemu-user` is the correct, much
   leaner package for binfmt-based cross-arch emulation.
4. `mmdebstrap` and standalone `kpartx` are absent from this nixpkgs
   snapshot; `debootstrap` and `multipath-tools` (which provides `kpartx`)
   are the respective substitutes.
5. The default dynamically-linked `busybox` package references a Nix store
   path as its ELF interpreter and won't run standalone on-device; use
   `pkgsCross.aarch64-multiplatform.pkgsStatic.busybox` instead.
6. defconfig's default `CONFIG_DEBUG_INFO=y` (DWARF, "reduced") makes the
   kernel's single, unparallelizable final `LD vmlinux.o` link step memory
   hungry enough to get OOM-killed on this shared 14 GB dev machine,
   independent of `-j` parallelism (compiles succeeded cleanly at `-j4`;
   only the serial link step failed, twice, before this was found).
   `CONFIG_DEBUG_INFO_NONE=y` fixes it.
7. Shell-exported build variables meant for one project's build (`ARCH`,
   `LLVM` in `shell.nix`, set for the Linux kernel) leak into other
   projects sharing the same shell (uniLoader) that use conflicting
   conventions for the same variable names (`ARCH=arm64` vs uniLoader's own
   `ARCH=aarch64`) — each build script must pass its own required values
   explicitly on the `make` command line rather than relying on the shared
   shell environment.

## First flash attempt (2026-09-05): Download Mode fallback, diagnosed

Flashed `boot`(uniLoader)/`init_boot`/`vendor_boot`/`dtbo` per the bundle
described above, rebooted — ABL fell back to Download Mode almost
immediately (recoverable via button combo, not a brick). Full sec-log
capture saved at `work/bringup-2026-09-05/last_kmsg-attempt1.txt`.

**Root cause, confirmed from the log, not guessed:**

- The log shows `LinuxLoader Load Address to debug ABL: 0xC44C9000` /
  `LinuxLoaderEntry Address: 0xC44C9B3C` — ABL loaded uniLoader
  *dynamically* at `0xC44C9000`, completely independent of the
  vendor_boot header's legacy `kernel_addr` field (which our build set to
  `0x80008000` — nowhere close). **This confirms ABL ignores that legacy
  field for physical placement on this device** — resolves what would
  otherwise still be an open question about vendor_boot v4 addressing.
- uniLoader's own `arch/aarch64/reloc.S` "position independent" mode is
  not true PIC: at entry it compares its actual runtime address against
  the Kconfig-compiled-in `TEXT_BASE`, and if they differ, does a
  **forward, non-overlap-safe `memcpy` of its entire ~43 MiB self** from
  the real load address to `TEXT_BASE` before jumping there.
- The original `TEXT_BASE=0xa8000000` (borrowed from `pong_defconfig`,
  Nothing Phone 2/SM8450 — a different device, never verified against this
  hardware) forced that self-copy to run needlessly. The log's last
  meaningful line before the Download Mode fallback is ABL's own `Exit
  Boot Services` — i.e. ABL completed its side of the handoff and jumped
  into uniLoader; nothing is logged after that (uniLoader has no logging
  hooked into this shared buffer either way), consistent with a crash
  during or immediately after that self-copy.
- **Fix applied**: `uniloader-overlay/gts9-5g_defconfig`'s `TEXT_BASE` is
  now `0xC44C9000` — the exact measured load address — making the
  relocation comparison succeed (source == destination) and skipping the
  copy entirely. Confirmed by inspecting the rebuilt ELF directly:
  `readelf -h uniLoader.o` shows `Entry point address: 0xC44C9000`,
  matching exactly. `PAYLOAD_ENTRY`/`RAMDISK_ENTRY` (unchanged) were
  manually checked against this new range and against the ABL's own
  logged "Add Base" available-memory regions from the same capture — no
  overlap, generous margins on both sides.
- **Caveat, since CONFIRMED true**: the second flash attempt (with
  `TEXT_BASE` set to exactly match attempt 1's measured address) *also*
  fell back to Download Mode, and its own sec-log capture
  (`last_kmsg-attempt2.txt`) shows ABL logging **two different**
  "LinuxLoader Load Address" values within that single power-on session
  (`0xC44C6000`, then `0xC44D0000` after what looks like an automatic ABL
  retry — a fresh "Loader Build Info"/"ONEUI VER" banner reprints in
  between), neither matching attempt 1's address or the `TEXT_BASE` we'd
  just set to match it. **The load address is not stable — matching one
  observed value is not a viable fix on its own.** uniLoader's self-copy
  relocation mechanism must actually work correctly (or the real bug lies
  elsewhere) rather than being avoidable by lucky guessing. See the
  bring-up checkpoint diagnostic added in `uniloader-overlay/board-gts9-5g.c`
  (writes progress markers directly into this same sec-log region from
  within uniLoader's `early_init`/`late_init` hooks) for the next step
  toward actual visibility into where execution stops.
- **Attempt 3 result: neither checkpoint fired.** Since `early_init` is
  only reached after `main()` is called, which only happens after
  uniLoader's own self-relocation code (`arch/aarch64/reloc.S`) finishes
  and jumps there, this means **execution never reaches `main()` at
  all** — narrowing the failure to the relocation copy itself or earlier.
  Patched `reloc.S` directly (`uniloader-overlay/reloc.S`, full-file
  replacement) with two raw-assembly checkpoints (magic+idx set
  explicitly, not just a byte poke, since `/proc/last_kmsg` only exposes
  `buf[0..idx)` — a poke without updating `idx` would be invisible even if
  it executed, caught and fixed before flashing) at `_reloc_entry`'s start
  and right before the final jump to `_start`. See `docs/porting-log.md`
  for the attempt-4 plan.
- **Attempt 4 result: still zero checkpoint signal**, even from raw
  assembly at the very first instruction of `_reloc_entry`. Verified via
  `objdump` that the compiled/linked instructions exactly match intent (no
  encoding bug) — the address computation and `str` instructions are
  correct. Also noticed something new: **every single attempt's ABL log
  shows `LinuxLoaderEntry Address` = `Load Address + 0xB3C`, exactly,
  regardless of the (varying) load address** — a suspiciously constant
  offset. Two hypotheses tested and both refuted:
  - Guessed it might reflect a gzip-wrapper convention (Samsung's ABL
    expecting `Image.gz` rather than a raw binary, matching uniLoader's
    own `CONFIG_COMPRESS_GZIP=y` default producing `uniLoader.gz` as an
    alternative artifact). **Tested attempt 5 with `uniLoader.gz` instead
    of the plain binary — the `+0xB3C` offset was identical, and the
    result was identical (Download Mode).** Rules this out.
  - Confirmed `text_offset` is `0` in both source
    (`linux-kernel-image-header.h`) and the linked binary's disassembly —
    a compliant bootloader jumping to `Load + text_offset` should land at
    `_head` (offset 0) exactly, not offset `0xB3C`. Since `0xB3C` is
    constant regardless of file content (plain vs. gzip, different
    addresses), it's most likely a fixed value ABL's own logging computes
    for display purposes, not necessarily reflecting the true jump target.
  - Separately confirmed (a genuine positive result): `AUTHENTICATE fail
    but allow` now confirmed logged for **all four** custom partitions
    (`boot`/`dtbo`/`vendor_boot`/`init_boot`), not just `vbmeta`/`recovery`
    — the AVB bypass is fully validated across the whole boot chain.
- **Open methodological concern, not yet resolved**: every failed attempt
  has been diagnosed via a TWRP → [crash] → Download Mode → [user exits] →
  TWRP round trip. `/proc/iomem` shows the sec_log region is tagged
  `System RAM`, which `STRICT_DEVMEM` policy (near-universal on production
  kernels) blocks from direct `/dev/mem` access even as root — confirmed
  by creating `/dev/mem` and trying `devmem`, which failed with "No such
  device or address" (the standard `devmem_is_allowed()` rejection for
  RAM-typed regions). **This means there is currently no way to directly
  verify whether entering/exiting Download Mode preserves or clears this
  DRAM region** — if it clears it, every "zero signal" conclusion above
  could be an artifact of the diagnostic path itself, not proof that our
  code never ran. No smoking-gun evidence either way yet.
- Also confirmed independently from this same log: the vbmeta
  flags=2/AVB-verification-disabled bypass works exactly as expected
  (`AUTHENTICATE fail but allow ... binary: vbmeta` /
  `verifystatus(2)` — logged explicitly for `vbmeta` and `recovery`).
- Unexplained/unconfirmed noise also present in the log (`SPSS Failed to
  load metadata`, `HdmAppSendCmd ... status=37`, `sec_update_cmdline:
  QUEST TOKEN FAIL`) — no stock-boot baseline log exists yet to compare
  against, so it's unknown whether these are new (caused by our changes)
  or present on every boot of this device regardless. Worth capturing a
  stock-boot log for comparison if they recur and start to look load-bearing.

### Root cause found (2026-09-05, attempt 6): the "Exit Boot Services"
diagnosis above was a misattribution — real failure is much earlier

After dropping uniLoader and testing a raw mainline kernel `Image`
(attempt 6), the result was superficially identical (Download Mode again)
— but this time the full `/proc/last_kmsg` capture was read carefully
line-by-line instead of just grepped for expected markers, and it
revealed the actual failure point directly, identically present **in all
six attempts including the five uniLoader ones**:

```
[ ABL ] No Valid Dtb
[ ABL ] Unable to find the Board Dtb
[ ABL ] Error: Board Dtbo blob not found
[ ABL ] Launching odin -927639495
```

Confirmed by grepping every saved capture
(`work/bringup-2026-09-05/last_kmsg-attempt{1,2,3,4,5-gzip,6-rawkernel}.txt`)
— this exact sequence is present in **all six**, at the point right after
ABL sets `SetDdiKernelType: init_boot` and before any kernel/payload code
could possibly run. **ABL never executed uniLoader or the mainline kernel
in any of the six attempts** — it fails its own DTB/DTBO validation step
and launches Odin (Download Mode) directly as an error path, before ever
reaching kernel decompression or jump. This also resolves the earlier
"every attempt ends at XBL `Exit Boot Services`/`+0xB3C`" observation from
attempts 1–4: that log content actually belongs to the **subsequent
automatic-fallback boot into `recovery` (TWRP)** after a warm reset
following the Odin launch, not to our own boot attempt — `SetDdiKernelType:
recovery` and a second `SetDdiKernelType: vbmeta` pass are visible
immediately before it in every capture. All of the uniLoader-specific
debugging (checkpoints, `TEXT_BASE`, gzip-vs-plain) was chasing a problem
that was never in uniLoader's code — the boot chain died at DTB/DTBO
validation, upstream of the kernel slot entirely, every single time.

**Concrete bug found and fixed**: `scripts/build-android-v4-bundle.sh`'s
`dtbo.img` fallback builder (used because `mkdtboimg.py` isn't vendored)
packed only **7** `uint32` header fields (28 bytes) while declaring
`header_size=32` and `dt_entries_offset=32` — Android's real
`dt_table_header` struct has **8** fields (adds a trailing `version`
field), confirmed directly against `backups/2026-09-05/dtbo.img`'s actual
header bytes (`d7b7ab1e 0031192e 00000020 00000020 00000004 00000020
00001000 00000000`). The missing field misaligned every subsequent byte
by 4, so ABL was parsing garbage for the (single, no-op) DTBO entry — a
plausible direct explanation for the exact "no valid/unable to find"
errors observed. Fixed by adding the `version=0` field to the struct pack
call. Rebuilt bundle's `dtbo.img` verified by unpacking the new header:
`entries_offset=32` now correctly lines up with the entry's actual byte
position (previously off by 4), entry `size=140, offset=64` are sane
relative to the embedded no-op blob.

**Attempt 7**: reflashed all four partitions with only `dtbo.img` content
changed (same raw-kernel `boot.img`/`init_boot.img`/`vendor_boot.img` as
attempt 6) to isolate this one variable. See `docs/porting-log.md` for the
result.

Open question if attempt 7 still fails the same way: whether ABL further
requires the DTBO table's single entry to carry non-zero `id`/`rev` fields
matching this board's actual board-id/soc-id (rather than accepting an
`id=0, rev=0` no-op/wildcard entry) — the stock `dtbo.img`'s entry 0 also
has `id=0, rev=0` though, which is at least suggestive that 0/0 is an
accepted default/always-match entry, not something ABL requires to be
board-specific.

## Open risks / unverified assumptions (carried into later phases)

1. ~~Whether X716's ABL has the same DTB-append-to-kernel /
   DTBO-fallback-to-inert-stub behavior the X910 reference relies on.~~ —
   **RESOLVED**, but not the way originally assumed: the working recipe is
   *not* "append DTB to boot, real dtbo table with fallback" — it's
   "`vendor_boot` carries the real DTB, `dtbo.img` is a **4096-byte
   all-zero blob** (not a DT table at all, not even an empty one), `boot`'s
   kernel is gzip'd with the DTB *also* appended after it." Adopted
   verbatim from `ubuntu-galaxy-tab-s9ultra` (same SM8550 generation,
   proven on real hardware) after six consecutive attempts all failed
   identically at ABL's own DTB/DTBO validation (`"No Valid Dtb"`) — see
   `docs/porting-log.md`'s "Session 4" entry for the full story and
   `docs/boot-strategy.md` for the current, validated boot chain.
2. ~~Whether ABL reads the boot DTB from `vendor_boot` or from `boot`~~ —
   **RESOLVED**: `vendor_boot`'s DTB is what's actually applied (confirmed
   by attempt 8's kernel correctly parsing this board's regulators/UFS/
   sec-log reserved-memory node); `boot`'s appended copy matches the X910
   recipe's structure but isn't the one in effect.
3. Whether the 5G SKU's ABL has board-id/partition-selection differences
   from the Wi-Fi-only X910 (e.g. due to the modem partition's presence).
   **Still unknown** — nothing found so far suggests a difference, but
   nothing has specifically tested for one either.
4. ~~Whether the `sec_log_buf_region` readback-via-TWRP debug channel
   actually works on this unit~~ — confirmed working for *early-to-mid*
   boot content (attempt 8 captured our own kernel's boot banner and
   sec-log driver registration cleanly), but **a real, hard capacity limit
   was found**: reaching TWRP at all requires a boot cycle whose own
   XBL/PBL/ABL preamble is verbose enough to overwrite our kernel's late-
   boot/userspace-stage output almost every time. Not useful for
   diagnosing anything past roughly the point attempt 8 reached. See
   `docs/porting-log.md`'s "the diagnostic channel hits a hard capacity
   wall" for the full investigation, and `docs/boot-strategy.md` for the
   two channels added to work around it (`simple-framebuffer`, persistent
   microSD logging) — as of this writing, both came back with no signal
   on the current (post-attempt-8) build, not yet root-caused. Superseded
   in practice: a working USB serial shell (see `docs/boot-strategy.md`'s
   item 8) now gives direct `dmesg` access, which is what later iteration
   actually used instead of chasing either of these two channels further.
5. ~~Display/panel bring-up (Session 5, 2026-09-05) is written but not yet
   flashed/validated on real hardware.~~ — **RESOLVED, first attempt**:
   flashed and confirmed working the same session. The panel shows real
   content (boot-logo Tux array, then a genuine fbcon text console), the
   DPU/DSI/panel driver stack bound with zero errors, and the panel ID
   read back `80 00 04` — matching, independently, the `lcd_id=800004`
   ABL's own stock firmware had already read from this exact physical
   panel (visible in the kernel cmdline). See `docs/porting-log.md`'s
   Session 5 entry ("Real-hardware validation") for the full `dmesg`
   evidence. One assumption was actively disproven in the process: the
   cold-boot suspend/resume DDIC-recovery quirk (needed on the X910
   Ultra's sibling panel) turned out to be unnecessary here — this
   panel's ID read correctly before that quirk ever ran.
