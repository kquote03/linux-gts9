# linux-tabs9-port

Porting mainline Linux + Ubuntu to a Samsung Galaxy Tab S9 5G (SM-X716B,
Qualcomm Snapdragon 8 Gen 2 / SM8550 "kalama").

This is hardware bring-up from near-zero: no existing mainline kernel/devicetree
port for this exact board was found anywhere. See `docs/hardware-facts.md` for
ground-truth device facts and `docs/porting-log.md` for a dated session-by-session
engineering diary — that diary is the authoritative record of what's been tried,
what worked, and why; this README only summarizes.

## Status

**Mainline Linux boots on this hardware and gives a real interactive shell.**
The kernel reaches `/init`, mounts a minimal bring-up ramdisk, and — over a USB
gadget serial console (`g_serial`/CDC-ACM, since there is no UART header on this
board) — a genuine `sh` prompt is reachable from a PC with nothing more than a
USB-C cable. `docs/porting-log.md`'s "Session 4" entry has the full story,
including six real kernel-config/devicetree bugs found and fixed to get there
(most were mainline defconfig defaulting a needed driver to `=m` with no
modprobe available at this bring-up stage — a recurring pattern, not six
unrelated problems).

**The display works, and so does a real Wayland session on it.** Mainline
DRM/KMS drives the internal panel (Samsung/Anapass ANA38407 DDIC, part
AMSA10FA01) via a from-scratch panel driver
(`kernel/drivers/panel-samsung-ana38407-x716.c`) — confirmed on real
hardware: the boot-logo Tux array, then a genuine fbcon text console with a
blinking cursor, with the whole DPU/DSI/panel stack binding with zero
errors in `dmesg`. A separate, minimal Buildroot-built rootfs (Weston +
weston-terminal, no Mesa/GPU — pixman software rendering only, ~14.4 MiB
compressed) builds cleanly, flashes into `vendor_boot`'s ramdisk slot
(too big for `init_boot`'s fixed 8 MiB — see `docs/porting-log.md`'s
Session 5 entry), and **weston-terminal renders on the panel**, confirmed
directly on the tablet. One fix (dropping a `--tty` flag that turned out
to fail, adding `--continue-without-input` since there's no touchscreen or
keyboard yet) was verified live over the serial shell but not yet baked
into a freshly-flashed image — rebuilding once more to pick that up is a
loose end, not a real unknown.

**Touchscreen has a driver, but is disabled pending a safe power fix.**
Mainline has no usable driver for the real chip (an ST fts1ba90a — the
in-tree `stmfts.c` targets an unrelated, older ST part), so
`kernel/drivers/touchscreen-fts1ba90a-x716.c` is a from-scratch port.
Enabling its DTS node (specifically, a PM8550-b LDO14 regulator node for its
AVDD rail) caused a real-hardware regression — a silent hard reset, no
kernel console output at all, killing display and USB. Root-caused (not yet
100% proven) to that regulator being TrustZone-restricted: a devicetree
node with matching min/max microvolts triggers an unconditional RPMH
voltage-set at PMIC registration time regardless of any consumer, unlike
the panel's regulators (same pattern, already proven safe). Removing the
node fixed the regression, confirmed on real hardware — see
`docs/porting-log.md`'s Session 6 entry for the full investigation (three
other hypotheses ruled out first). The driver and DTS node stay in the tree,
disabled, until a safe way to power this rail is found.

**What doesn't work yet:** a real root filesystem (still a debug-only ramdisk;
see Phase 4 below), touchscreen (see above), WiFi/BT, camera, audio, sensors,
fingerprint, S-Pen, keyboard cover, cellular/modem, GPU acceleration, and
full USB-C role negotiation (the gadget console works because `&usb_1`'s
`dr_mode` is forced to `"peripheral"`, deliberately bypassing the Type-C
PD/role-switch chain — `ps5169`/`sm5714-usbpd` stay unbound as a result,
which is fine for a fixed USB2 console but would need real work for dynamic
host/device switching or charging). Internal UFS storage also isn't
reachable yet (stuck in the kernel's own deferred-probe mechanism) — Phase 4
targets the microSD card instead, specifically so this isn't a blocker.

## Connecting to the shell (once flashed and booted)

The tablet enumerates as a USB serial gadget. From a PC with the tablet
plugged in via USB-C:

```sh
nix-shell -p picocom --run "picocom -b 115200 /dev/ttyACM0"
# or: nix-shell -p screen --run "screen /dev/ttyACM0 115200"
```

Press Enter once or twice for a prompt. On the debug ramdisk this drops
straight into a shell (if it looks stuck — stray input from something else
that wrote to the port — send Ctrl-D once, it respawns a fresh shell
automatically). On the Weston rootfs it's a real login prompt instead
(`buildroot login:`) — log in as `root` with an empty password (just press
Enter at the password prompt). Exit picocom with Ctrl-A then Ctrl-X; exit
screen with Ctrl-A then `k`, then confirm.

## Scope

**Goal (MVP):** a mainline kernel that boots to a shell with a real Ubuntu
root filesystem reachable over SSH/USB networking. Console-less debugging via
a persistent log carveout (`sec_log_buf_region`) and a USB gadget serial
console, since there is no UART cable.

**Explicit non-goals for this phase of the project:**

- Cellular/modem — no mainline story exists for Samsung's Shannon modem IPC on
  this SoC; the `modem` partition is left untouched permanently.
- Touchscreen, WiFi/BT, camera, audio, sensors, fingerprint, S-Pen,
  keyboard cover — all deferred to future work once the MVP boots. (Display
  is no longer a non-goal — see Status above — but GPU acceleration for it
  still is: the Weston rootfs deliberately uses software rendering only.)
- Full USB-C PD/role negotiation — the gadget console uses a fixed peripheral
  role; real Type-C role switching, charging, and DisplayPort alt-mode are
  deferred (see `docs/porting-log.md`'s "Session 4" entry for the full trace
  of what would be needed).
- Repartitioning internal UFS storage — the MVP root filesystem targets the
  microSD card instead, to avoid touching internal partitions before the
  kernel is proven stable (and because UFS itself isn't reachable yet — see
  Status above).

## Reproducing this from a fresh machine

Everything needed is either vendored in this repo or fetched by a pinned
script — nothing here depends on state from the machine this was developed
on. You need: [Nix](https://nixos.org/download) (for `nix-shell`; the flake-free
classic CLI is enough), a Linux host (for the AArch64 cross toolchain and
`adb`), and the actual tablet, TWRP-flashed and unlocked, connected over USB.

```sh
git clone git@github.com:kquote03/linux-gts9.git
cd linux-gts9
nix-shell   # everything below runs inside this shell

# 1. Fetch pinned sources (exact commits recorded in each script; see also
#    docs/hardware-facts.md for why these particular pins were chosen)
bash scripts/fetch-mainline.sh      # mainline Linux v7.2, pinned commit
# bash scripts/fetch-uniloader.sh   # NOT needed for the active boot path —
                                    # see "uniLoader" note below

# 2. Build the kernel + board DTB (installs the board DTS, the sec-log
#    driver, and the USB Type-C drivers into the fetched kernel tree, merges
#    kernel/config/config-mainline.aarch64 + config-x716.fragment, builds)
bash scripts/build-mainline-kernel.sh

# 3. Build a ramdisk -- either the debug-only bring-up ramdisk (static
#    busybox + a minimal /init) or the minimal Weston rootfs (step 3b);
#    not the real Ubuntu rootfs, that's Phase 4, not yet written
bash scripts/build-bringup-ramdisk.sh

# 3b. (optional) instead of 3: the Weston + weston-terminal rootfs --
#     confirmed working on real hardware (weston-terminal rendering on
#     the panel), see docs/porting-log.md's Session 5 entry. This is a
#     real build-from-source (Buildroot builds its own toolchain + every
#     package), so it takes a while -- ~15 MiB compressed once done,
#     deliberately built with no Mesa/GPU (pixman software rendering only).
# bash scripts/fetch-buildroot.sh
# bash scripts/build-buildroot-rootfs.sh

# 4. Package boot.img/init_boot.img/vendor_boot.img/dtbo.img (reads the
#    debug ramdisk by default; the Weston rootfs needs a different
#    invocation -- see below -- since it's too big for init_boot's fixed
#    8 MiB partition and has to go into vendor_boot's 96 MiB one instead)
bash scripts/build-android-v4-bundle.sh

# or, for the Weston rootfs from step 3b: init_boot gets a genuinely
# empty ramdisk (nothing in it to conflict with vendor_boot's real
# rootfs, whichever way ABL concatenates the two at boot) and vendor_boot
# gets the real Weston rootfs.
# bash scripts/build-empty-ramdisk.sh
# INIT_BOOT_RAMDISK=out/empty-ramdisk.cpio.gz \
#     VENDOR_RAMDISK=out/buildroot/images/rootfs.cpio.gz \
#     bash scripts/build-android-v4-bundle.sh

# 5. Flash (TWRP must be running and reachable via `adb devices`; this is
#    the ONLY script in the repo that writes to the device, and it refuses
#    to run without the explicit flag below — read docs/boot-strategy.md's
#    pre-flash checklist first, and take a fresh TWRP backup of at least
#    boot/init_boot/vendor_boot/dtbo before your first flash)
bash scripts/flash-boot-set.sh --i-understand-this-writes-to-the-device \
    boot=out/android/boot.img init_boot=out/android/init_boot.img \
    vendor_boot=out/android/vendor_boot.img dtbo=out/android/dtbo.img

# 6. Reboot the tablet (from TWRP: reboot to system/normal boot, not
#    recovery), then connect per "Connecting to the shell" above.
adb reboot
```

**uniLoader note:** an earlier phase of this project used
[uniLoader](https://github.com/ivoszbg/uniLoader) as an intermediate
bootloader, modeled on a sibling device that needs it. It turned out to be
unnecessary for this specific chip generation (see `docs/porting-log.md`) and
was dropped — `scripts/fetch-uniloader.sh`, `scripts/build-uniloader.sh`, and
`uniloader-overlay/` remain in the repo, unused, in case it's worth
revisiting later, but the steps above don't need them.

**No kernel rebuild needed for most iteration:** steps 3-6 alone (skip step 2)
are enough after changing only the ramdisk or repackaging; step 2 is only
needed after a devicetree or kernel-config change.

## Repo layout

- `docs/` — `hardware-facts.md` (ground-truth device facts, what's measured
  vs. assumed vs. inherited from a reference device), `porting-log.md` (the
  full session-by-session diary — start here for *why*, not just *what*),
  `boot-strategy.md` (the boot chain, pre-flash checklist, recovery plan).
- `kernel/dts/` — the board devicetree.
- `kernel/config/` — Kconfig fragments merged on top of `defconfig`.
- `kernel/drivers/` — from-scratch drivers written for this port: a
  console-less debug log (`samsung-x716-sec-log.c`), the USB Type-C stack
  (`ps5169.c`, `sm5714_battery.c`, `sm5714_usbpd.c` — GPL-2.0 reimplementations
  originally written for `ubuntu-galaxy-tab-s9ultra`, adapted here), and the
  display panel driver (`panel-samsung-ana38407-x716.c` — forked from that
  same reference project's own ANA38407-family driver, with DCS byte
  sequences re-derived for this board's specific panel part).
- `scripts/` — every build/fetch/flash step; `flash-boot-set.sh` is the only
  one that touches the device.
- `buildroot/` — `configs/x716_defconfig` (the minimal Weston rootfs's
  Buildroot config) and `rootfs-overlay/` (its `/etc/init.d/S99weston`
  autostart script). A separate, smaller thing from the Phase 4 Ubuntu
  rootfs — see Status above.
- `uniloader-overlay/` — unused (see uniLoader note above), kept for later.
- `third_party/android-tools/` — vendored `mkbootimg`/`avbtool` (Apache-2.0,
  from AOSP; see `third_party/android-tools/PROVENANCE.md`).
- `shell.nix` — the entire build toolchain, pinned via the host's nixpkgs.

## Inputs (not part of this repo's history — see `.gitignore`)

- `android_kernel_samsung_gts9/` — Samsung's stock downstream kernel/devicetree
  source for this board family. Used as a reference for hardware wiring
  (regulator names, GPIO numbers, reserved-memory addresses, i2c addresses),
  not as code to copy — it targets a completely different (downstream, GKI
  5.15) kernel ABI.
- `ubuntu-galaxy-tab-s9ultra/` — a working mainline Ubuntu port for the sibling
  SM-X910 "Ultra" tablet (same SoC generation, different board). The single
  most valuable reference this project used: its boot-chain recipe (how to
  get ABL to accept a mainline DTB at all) and its USB Type-C driver work
  were both adopted here after failing to find the same result independently.
- `sm-x800-linux/` — a working mainline postmarketOS port for the Galaxy Tab
  S8+ (a different, older SoC generation). Used to understand a failure mode
  (Samsung's ABL corrupting a mainline devicetree via DTBO overlays) that
  turned out to have a different fix on this device's newer chip generation
  — see `docs/porting-log.md`'s "Session 4" for why the two boards' answers
  diverged.
- A TWRP nandroid backup of this exact tablet's `boot`/`init_boot`/
  `vendor_boot`/`dtbo`/`modem` partitions, used to derive ground-truth
  partition sizes and boot image formats.

## Safety

Every device-write step in this project requires a fresh verified TWRP backup
and explicit per-step confirmation before it runs — see `docs/boot-strategy.md`.
`scripts/flash-boot-set.sh` is the only script that writes to the device, and
it refuses to run without an explicit acknowledgement flag for exactly that
reason. Unlocking this tablet's bootloader and installing TWRP are
prerequisites this repo assumes are already done — that process itself
(covered elsewhere, not in this repo) permanently trips Knox on Samsung
devices.
