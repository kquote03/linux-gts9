# linux-tabs9-port

Mainline Linux + a Fedora 44/GNOME userland on the Samsung Galaxy Tab S9 5G
(SM-X716B, Qualcomm Snapdragon 8 Gen 2 / SM8550 "kalama"): native display,
GPU acceleration, touch, S Pen, Wi-Fi, Bluetooth, stereo speakers, battery/
PPS charging, power and volume buttons, and a real GNOME desktop — booting
from the eMMC Android boot chain into a Fedora root on the microSD.

This is hardware bring-up from near-zero: no existing mainline kernel/
devicetree port for this exact board was found anywhere. It ports
[gts9wifi-fedora](https://github.com/nacht20-de/gts9wifi-fedora) (a mature,
real-hardware-validated Fedora port for the Wi-Fi-only sibling tablet,
SM-X710) wholesale, adapting it to the 5G board's own facts, and vendors
that project in full at `gts9wifi-fedora/`. See `docs/hardware-facts.md`
for ground-truth device facts and `docs/porting-log.md` for a dated
session-by-session engineering diary — that diary is the authoritative
record of what's been tried, what worked, and why; this README only
summarizes.

Verified on hardware end to end: cold boot to a real GNOME login screen,
GPU acceleration from first probe, both stereo speaker channels audible,
real Wi-Fi association, and a power button that genuinely suspends the
device.

## What works

| Area | Status |
|---|---|
| Display (2560×1600 AMOLED, Samsung/Anapass ANA38407, DSI+DSC) | ✅ |
| GPU (Adreno 740) | ✅ real zap/GMU firmware, GNOME renders on it |
| Touchscreen (ST fts1ba90a) | ✅ |
| S Pen digitizer (Wacom wez01) | ✅ confirmed on hardware, tracks correctly across display rotations (see `docs/s-pen-orientation.md`) |
| Wi-Fi (QCA6490 / ath11k) | ✅ real AP association confirmed |
| Bluetooth | ✅ firmware loaded, HCI up |
| Speakers (4× CS35L45 on PRIMARY MI2S) | ✅ both stereo channels confirmed audible by ear |
| DMIC capture (LPASS VA macro) | ⚠️ wired in DTS, not yet tested with a real recording |
| Battery / charging incl. PPS (SM5714 + SM5440) | ⚠️ real PD/PPS contract confirmed negotiating (`docs/porting-log.md`), needs more extended real-world testing before calling it fully proven |
| Power / volume buttons | ✅ confirmed on hardware (power suspends; both volume keys work) |
| Book-cover lid switch | ❌ not implemented |
| USB (gadget debug network) | ✅ `g_ether`, real SSH access |
| USB host mode, Type-C PD, docks | ✅ confirmed on hardware — real USB-C hub enumerated fully (`docs/porting-log.md`) |
| USB-C DisplayPort altmode | ⚠️ wired in DTS, not tested with a physical dock |
| Sensors (SSC: accelerometer, ambient light, etc.) | ⚠️ ADSP boots and the HexagonFS registry path is fixed, but the SSC QMI service itself doesn't publish (a real, likely upstream `hexagonrpcd` gap — see `docs/porting-log.md`) |
| Suspend (s2idle) | ✅ |
| GNOME desktop (Wayland, `gdm`) | ✅ real login screen confirmed on the physical panel |
| Camera | ❌ no drivers (gts9wifi-fedora's own reference doesn't have this either) |
| Fingerprint | ❌ not present on the reference project this was ported from |
| Hardware video decode (iris) | ❌ not sourced |
| `/vendor` super partition (erofs) | ❌ needs a `make-dynpart-mappings` port neither project has done |
| Cellular / 5G modem | ❌ permanent non-goal — no mainline story for Samsung's Shannon modem IPC on this SoC |

## Connecting to the tablet (once flashed and booted)

The rootfs enables `sshd` and brings up a debug USB gadget network
(`g_ether`, address `172.16.42.1`) alongside real Wi-Fi. From a PC:

```sh
# over the USB gadget link (plug in via USB-C, no host network needed)
ssh x716b@172.16.42.1

# or over real Wi-Fi, once it's associated to a network
ssh x716b@<tablet's-dhcp-address>
```

Default credentials are `x716b` / `x716b` for both the `x716b` user (in
`wheel`, full sudo) and `root`. Override the username at rootfs-build time
with `GTS9_USER`.

## Reproducing this from a fresh machine

Everything needed is either vendored in this repo or fetched by a pinned
script — nothing here depends on state from the machine this was developed
on, **except** the device-specific firmware in `vendor-firmware-dump/`
(ADSP PIL images, PDR service-registry files, HexagonFS skel libs), which
is committed too so the whole build works from this repo alone, but is
only ever *regenerated* from this exact tablet's own partitions via TWRP.
You need: [Nix](https://nixos.org/download) (`nix develop`/`nix run`,
flakes enabled), a Linux host (for the AArch64 cross toolchain and `adb`),
and the actual tablet, TWRP-flashed and unlocked, connected over USB.

```sh
git clone git@github.com:kquote03/linux-gts9.git
cd linux-gts9
nix develop   # flake.nix — pins the exact toolchain (dnf5, the aarch64
              # cross compiler, qemu-user for the rootfs build's binfmt
              # chroot, …) this project's own dev machine builds from.
              # Documented as pinning *tool versions*, not full rootfs-
              # content hermeticity — Fedora package content is only as
              # reproducible as Fedora's own repos, matching
              # gts9wifi-fedora's own CI model. shell.nix still works too
              # (`nix-shell`) for anyone not using flakes.

# 1. Fetch pinned sources
bash scripts/fetch-mainline.sh          # mainline Linux v7.2, pinned commit

# 2. (only if re-deriving device-specific firmware from scratch) with the
#    tablet in TWRP and reachable via `adb devices`:
bash scripts/extract-vendor-firmware.sh # ADSP PIL firmware + PDR .jsn
                                         # files + HexagonFS skel libs from
                                         # this exact device's own apnhlos/
                                         # dsp partitions, plus the
                                         # AudioReach topology binary
                                         # (reused + patched from upstream
                                         # linux-firmware, not device-
                                         # specific — see
                                         # scripts/stage-audioreach-
                                         # topology.sh's own header).
                                         # Already committed under
                                         # vendor-firmware-dump/, so this
                                         # step is only needed to
                                         # regenerate it.

# 3. Build the kernel + board DTB
nix run .#build-kernel

# 4. Build the Fedora rootfs (dnf5 --forcearch=aarch64, real source builds
#    of libssc/pd-mapper/hexagonrpcd/iio-sensor-proxy, the full device
#    overlay applied — see docs/distro-porting.md). Slow: this is a real
#    rootfs build, not a container pull.
nix run .#build-rootfs

# 5. Package boot.img/init_boot.img/vendor_boot.img/dtbo.img. Needs the
#    real root-mounting initramfs, not the bring-up ramdisk the script
#    still defaults to:
BRINGUP_RAMDISK="$(pwd)/out/real-root-initramfs.cpio.gz" \
    nix run .#build-bundle

# 6. Write the built rootfs to a microSD card (see docs/boot-strategy.md),
#    then flash the boot bundle (TWRP must be running and reachable via
#    `adb devices`; this is the ONLY step that writes to the device, and
#    it refuses to run without the explicit flag below — read
#    docs/boot-strategy.md's pre-flash checklist first, and take a fresh
#    TWRP backup of boot/init_boot/vendor_boot/dtbo before your first
#    flash)
nix run .#flash -- --i-understand-this-writes-to-the-device \
    boot=out/android/boot.img init_boot=out/android/init_boot.img \
    vendor_boot=out/android/vendor_boot.img dtbo=out/android/dtbo.img

# 7. Reboot the tablet (from TWRP: reboot to system, not recovery), then
#    connect per "Connecting to the tablet" above.
adb reboot
```

**No kernel rebuild needed for most iteration:** once a rootfs is on the
microSD, most changes (rootfs overlay content, firmware files, mixer/UCM
config) can be pushed live over SSH — see `docs/porting-log.md` for the
live-iteration pattern this whole port actually used. Steps 3 and 5-7 are
only needed after a devicetree or kernel-config change; step 4 only after
a rootfs-build-script or overlay change.

**uniLoader note:** an earlier phase of this project used
[uniLoader](https://github.com/ivoszbg/uniLoader) as an intermediate
bootloader, modeled on a sibling device that needs it. It turned out to be
unnecessary for this specific chip generation (see `docs/porting-log.md`)
and was dropped — `scripts/fetch-uniloader.sh`, `scripts/build-uniloader.sh`,
and `uniloader-overlay/` remain in the repo, unused, in case it's worth
revisiting later.

**Other rootfs builders in this repo** (`build-alpine-rootfs.sh`,
`build-buildroot-rootfs.sh`, `build-ubuntu-rootfs.sh`) predate the ADSP/
audio/sensor/button work and haven't been revisited since the Fedora
pivot — see `docs/distro-porting.md` before reviving any of them.

## Repo layout

- `docs/` — `hardware-facts.md` (ground-truth device facts, what's measured
  vs. assumed vs. inherited from a reference device), `porting-log.md` (the
  full session-by-session diary — start here for *why*, not just *what*),
  `boot-strategy.md` (the boot chain, pre-flash checklist, recovery plan),
  `distro-porting.md` (how the userspace device overlay splits into a
  distro-agnostic layer every rootfs builder applies vs. each distro's own
  init-system-specific layer — read this before adding a new rootfs
  builder or a new hardware-workaround script).
- `gts9wifi-fedora/` — vendored copy (nested `.git` stripped) of the real,
  hardware-validated X710 Fedora port this project ports from throughout:
  DTS nodes, kernel patches, the rootfs build script's own structure,
  systemd units/UCM configs/udev rules, the `hexagonrpcd` Samsung sensor-
  registry patches.
- `rootfs/overlay-common/` + `rootfs/overlay-systemd/` — the userspace
  device overlay (systemd units, udev rules, ALSA UCM configs, hardware-
  workaround scripts), split per `docs/distro-porting.md`; applied by
  `scripts/build-fedora-rootfs.sh`.
- `specs/` — `hexagonrpcd-samsung/` and `iio-sensor-proxy-libssc/` patch
  sets + spec files for the sensor/audio userspace daemons built from
  source (not packaged in Fedora).
- `vendor-firmware-dump/` — this exact device's own extracted ADSP PIL
  firmware, PDR service-registry `.jsn` files, and HexagonFS skel libs
  (real Samsung/Qualcomm binaries, not authored by this project — the
  redistribution-rights caveat in `.gitignore` applies), plus the
  AudioReach topology binary (not device-specific — reused + one-token-
  patched from upstream `linux-firmware`, see
  `scripts/stage-audioreach-topology.sh`).
- `kernel/dts/` — the board devicetree.
- `kernel/config/` — the Kconfig fragment merged on top of `defconfig`.
- `kernel/patches/` — out-of-tree patches applied to the pinned mainline
  tree (eUSB2 PHY init, MSM DP bridge/HPD fixes, TCPM role retention, MI2S
  codec DAI format, this port's own HexagonFS root-mapping fix).
- `kernel/drivers/` — from-scratch/ported drivers: a console-less debug log
  (`samsung-x716-sec-log.c`), the USB Type-C stack (`ps5169.c`, `sm5714_battery.c`,
  `sm5714_usbpd.c`), the display panel driver
  (`panel-samsung-ana38407-x716.c`), the touchscreen driver
  (`touchscreen-fts1ba90a-x716.c`), the S Pen digitizer
  (`touchscreen-wacom-wez01-x716.c`), and the PPS charge-pump driver
  (`sm5440_direct.c`) — several originally written for
  `ubuntu-galaxy-tab-s9ultra` or `gts9wifi-fedora`, adapted here.
- `scripts/` — every build/fetch/flash/extract step; `flash-boot-set.sh` is
  the only one that touches the device.
- `buildroot/` — a separate, smaller "prove the display works" Weston
  rootfs, not the main Fedora target — see `docs/distro-porting.md`.
- `uniloader-overlay/` — unused (see uniLoader note above), kept for later.
- `third_party/android-tools/` — vendored `mkbootimg`/`avbtool` (Apache-2.0,
  from AOSP; see `third_party/android-tools/PROVENANCE.md`).
- `flake.nix` / `shell.nix` — the build toolchain, pinned via nixpkgs.

## Inputs (not part of this repo's history — see `.gitignore`)

- `android_kernel_samsung_gts9/` — Samsung's stock downstream kernel/devicetree
  source for this exact device. The single most authoritative source for
  real GPIO numbers and hardware wiring (regulator names, reserved-memory
  addresses, i2c addresses, button GPIOs) — used as a reference, not as
  code to copy, since it targets a completely different (downstream, GKI)
  kernel ABI.
- `ubuntu-galaxy-tab-s9ultra/` — a working mainline Ubuntu port for the
  sibling SM-X910 "Ultra" tablet (same SoC generation, different board).
  A frequent second-opinion reference alongside `gts9wifi-fedora/` — its
  boot-chain recipe, USB Type-C driver work, AudioReach topology handling,
  and button wiring were all cross-checked here.
- `sm-x800-linux/` — a working mainline postmarketOS port for the Galaxy Tab
  S8+ (a different, older SoC generation). Used early on to understand a
  failure mode (Samsung's ABL corrupting a mainline devicetree via DTBO
  overlays) that turned out to have a different fix on this device's newer
  chip generation.
- A TWRP nandroid backup of this exact tablet's `boot`/`init_boot`/
  `vendor_boot`/`dtbo`/`modem` partitions, used to derive ground-truth
  partition sizes and boot image formats, and as the rollback plan before
  every flash.

## Safety

Every device-write step in this project requires a fresh verified TWRP
backup and explicit per-step confirmation before it runs — see
`docs/boot-strategy.md`. `scripts/flash-boot-set.sh` is the only script
that writes to the device, and it refuses to run without an explicit
acknowledgement flag for exactly that reason. Unlocking this tablet's
bootloader and installing TWRP are prerequisites this repo assumes are
already done — that process itself (covered elsewhere, not in this repo)
permanently trips Knox on Samsung devices.
