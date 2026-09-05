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
4. ~~Whether the `sec_log_buf_region` readback-via-TWRP debug channel
   actually works on this unit~~ — **RESOLVED, confirmed working** via a
   direct end-to-end test on 2026-09-05 (stock Android → TWRP, real content
   read back at the exact expected size). See the sec-log driver section
   above for details. Remaining uncertainty is narrower: whether *our*
   driver's later probe time (`arch_initcall`) captures enough before a
   possible early hang — not whether the channel works at all.
