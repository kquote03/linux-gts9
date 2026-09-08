# S Pen: fixing "stuck in one orientation" across display rotation

## Symptom

With GNOME's display rotation manually set to one specific state
("portrait right"), the S Pen tracked the tip correctly. In every other
rotation -- including the panel's own native landscape -- the pen kept
using that same portrait-right geometry instead of following the screen.
gts9wifi-fedora (the X710 project this whole port is based on) never
solved this either; their own README lists the S Pen as "detected, but
input behaves erratically."

Two independent, additive bugs, both confirmed on real hardware.

## Bug 1: the pen's raw coordinate frame didn't match the panel's native frame

`kernel/dts/sm8550-samsung-x716b.dts`'s `digitizer@56` node (the Wacom
WEZ01 EMR digitizer, driven by
`kernel/drivers/touchscreen-wacom-wez01-x716.c`) carried none of the
`touchscreen-swapped-x-y`/`touchscreen-inverted-x`/`-y` properties that
the *touchscreen* node right above it needed, for the identical reason
(see `docs/porting-log.md`'s Session 7 entry) -- the touchscreen's raw
sensor axes didn't match the panel's mounted orientation either, and the
fix there was DTS-only, at the kernel level. The pen driver already calls
`touchscreen_parse_properties()`/`touchscreen_report_pos()` (so it fully
supports these properties), but with none set it reported completely raw
axes.

Confirmed algebraically before ever touching the device: the driver's own
queried limits (`docs/porting-log.md`: `max_x 14752, max_y 23603`) at its
fixed 100 units/mm resolution (`WEZ01_RES_UNITS_PER_MM`) work out to
**147.52mm x 236.03mm** of raw sensor travel. The panel's real physical
size, from its own DTS property (`docs/hardware-facts.md`,
`qcom,mdss-pan-physical-{width,height}-dimension`), is **236mm x 148mm**
in landscape/native orientation. The pen's raw X axis matched the panel's
*short* dimension and raw Y matched the *long* one -- X and Y were
swapped relative to native, exactly matching "aligned only in a
90°-rotated state."

**Fix**: added `touchscreen-swapped-x-y` and `touchscreen-inverted-x` to
the `digitizer@56` node, starting from the touchscreen's own confirmed
combination (both sensors sit on the same panel). Confirmed live on
hardware after flashing: `udevadm info` on the pen's event node now
reports `ID_INPUT_WIDTH_MM=236` / `ID_INPUT_HEIGHT_MM=147` -- udev's own
computed size from the driver's post-swap `ABS_X`/`ABS_Y` ranges, matching
the panel's real physical landscape size almost exactly. The user
confirmed correct pen tracking by direct use afterward, cycling through
multiple display rotations, not just the "normal" baseline.

## Bug 2: GNOME/mutter never managed this device's rotation at all

`wacom_wez01_probe()` sets `INPUT_PROP_DIRECT` (correct -- marks it as a
direct/display-integrated device), but the device also reports
`BTN_TOOL_PEN`, so udev/libinput classify it as a **tablet tool**, not a
touchscreen (confirmed live: `udevadm info` reports `ID_INPUT_TABLET=1`,
not `ID_INPUT_TOUCHSCREEN`). For touchscreens, mutter applies the
output's rotation transform generically and automatically. For tablet
tools, that same automatic per-rotation calibration only happens for
tablets `libwacom` recognizes as integrated into the built-in display
(`IntegratedIn=Display` in a `.tablet` database file, matched via
`DeviceMatch=<bus>|<vendor>|<product>` against the kernel input device's
own `id.vendor`/`id.product`). The driver never set those fields (both
stayed 0) and no `.tablet` file existed for this hardware, so GNOME never
touched its calibration matrix -- it stayed at the identity mapping
forever, which only happened to look right in whichever single rotation
matched the pen's raw frame.

This mechanism isn't a guess: this project's own built rootfs already
ships `.tablet` files for two real-world devices in the exact same
class -- I2C EMR/AES pen digitizers built into a laptop's own display, no
USB VID/PID (`wacom-isdv4-527e.tablet` for the Lenovo X1 Yoga,
`elan-2f2a.tablet`) -- confirming this is the standard, portable
mechanism any libwacom-linked desktop (GNOME, KDE) uses for exactly this
situation.

**Fix, two parts**:

1. `kernel/drivers/touchscreen-wacom-wez01-x716.c`: after
   `input->id.bustype = BUS_I2C;`, set `input->id.vendor = 0xf000;` and
   `input->id.product = 0x0056;` -- a stable, made-up-but-fixed identifier
   pair (this IC isn't Wacom-licensed, so it has no real USB/ACPI
   vendor-product pair to report; `0x0056` doubles as a reminder of the
   digitizer's i2c address). Checked against every `DeviceMatch=i2c|...`
   entry already shipped in this project's built rootfs
   (`out/fedora/rootfs-gnome/usr/share/libwacom/*.tablet`) for collisions
   before picking it -- none.
2. New `rootfs/overlay-common/usr/share/libwacom/samsung-wez01.tablet`:
   `DeviceMatch=i2c|f000|0056` matching (1), `Class=ISDV4`,
   `IntegratedIn=Display;System`, `Width=236`/`Height=148` (mm, the real
   panel physical size), `Stylus=true`.

Confirmed live: pushing this file to `/usr/share/libwacom/` on the
already-running device flipped `libwacom-list-local-devices` from
"`/dev/input/event3` is a tablet but not supported by libwacom" to fully
recognizing it (`Samsung Galaxy Tab S9 5G S Pen`, `IntegratedIn=Display`,
correct styli list). The user then confirmed on real hardware that the
pen tracks correctly across multiple display rotations, not just one
fixed state -- the actual regression test for the original bug.

## Why this is distro-agnostic

Both fixes live below the desktop-environment layer:

- The DTS/driver changes are pure kernel content -- they affect every
  userland this project ever boots, not just Fedora/GNOME.
- The `.tablet` file lives in `rootfs/overlay-common/`, not
  `overlay-systemd/` (see `docs/distro-porting.md` for that split's
  rules) -- `libwacom` is a standalone library consumed by any
  libwacom-linked desktop (GNOME's mutter, KDE's KWin), on any init
  system, not something wired to systemd or to Fedora's packaging. It's
  the same class of dependency this project already leans on elsewhere
  (e.g. `iio-sensor-proxy`'s mount-matrix rules, also in
  `overlay-common/`).

No GNOME-specific dconf/gsettings state, no systemd unit, and no
Fedora-specific packaging step were needed for either half of the fix.

## A real build/flash mistake found along the way (not a regression)

While bringing up this fix, a flash appeared to hang the tablet on boot.
Bisecting by reflashing the pre-fix kernel/DTB reproduced the exact same
symptom, which at first looked like a red herring (or worse, a sign of
card corruption) -- until the tty showed the actual cause: `exFAT-fs
(mmcblk0p1) invalid boot record signature`. Both flashes had used
`nix run .#build-bundle` **without** the required `BRINGUP_RAMDISK`
override, so both silently fell back to `scripts/build-android-v4-bundle.sh`'s
stale default, `out/bringup-ramdisk.cpio.gz` -- the original "is the
kernel alive" debug ramdisk from early bring-up
(`scripts/build-bringup-ramdisk.sh`), which still does
`mount -t exfat /dev/mmcblk1p1` from before this project repartitioned
the microSD to ext4. It was never able to reach the real rootfs, on
either flash, regardless of any source change. Reflashing with
`BRINGUP_RAMDISK=$(pwd)/out/real-root-initramfs.cpio.gz` set booted
cleanly in the normal ~40s. No SD corruption, no kernel/DTS regression --
just a missing env var on this session's own `build-bundle` invocations.
Left here as a reminder for future sessions: always set `BRINGUP_RAMDISK`
explicitly when building a bundle meant to reach the real rootfs.
