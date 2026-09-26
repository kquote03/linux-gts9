# Off-mode charging and idle power

What happens when the tablet is powered on by a charger rather than the power
key, and the idle-power policy that lets an ordinary USB port charge it.
Engineering history is in `docs/porting-log.md` (Session 25).

## Why an ordinary USB port never charged the tablet

Measured on the tablet plugged into a PC (BC1.2 SDP, 5 V / 500 mA, so about
2.5 W of input), battery current from the SM5714 gauge, negative = discharging:

| State (screen/etc.)                               | Net battery current |
|---------------------------------------------------|---------------------|
| Greeter on, backlight 248/2047                     | about -265 mA       |
| Backlight 0                                        | about -120 mA       |
| Backlight 0, Wi-Fi off                             | about -60 mA        |
| Backlight 0, Wi-Fi off, gdm stopped                | about -7 mA         |
| Panel blanked (`fb0` FB_BLANK_POWERDOWN)           | **+480 mA**         |
| Idle greeter after the 60 s blank policy below     | +330 mA             |

The charger driver was never the problem: its SDP limit (500 mA input) matches
Android's `cable-info` for SDP (475 mA).  The panel simply drew more than the
port can supply, and the login screen never blanked.  Android has the same
500 mA ceiling; it charges from a PC because its screen turns off.

Fix: `rootfs/overlay-systemd/etc/dconf/db/{local,gdm}.d/00-gts9wifi-power`
blank the panel after 60 s (both the greeter and user sessions), suspend on
battery after 5 minutes, and never suspend on AC (a plugged-in tablet stays
reachable over SSH).  `scripts/build-fedora-rootfs.sh` runs `dconf update`.

## Charger tuning ported from the reference tree

- Float voltage: the SM5714 comes up at its OTP 4.38 V; the pack wants 4.44 V
  (`voltage-max-design-microvolt`).  `sm5714_battery.c` programs CHGCNTL4 at
  probe and again on every `sm5714_configure_charging()` (the chip forgets it
  after a long unplug).  Without it the gauge stops at 96-99 %.
- `fast_charge` (sysfs, default on): raises the 9 V input budget from 1.66 A to
  3 A and the pack goal from 2.8 A to the stock 3150 mA.  Also gates the
  SM5440 PPS pump.  The sink PDO in the DTS is now 9 V / 3 A so a 27 W+ fixed
  source can grant it.  udev rule `72-gts9wifi-charger-perms.rules` makes the
  attribute writable by group `video`.

## Off-mode charging screen

Samsung's ABL boots our image when a charger starts the tablet, and this used
to run the whole kernel and userspace.  `scripts/build-real-root-initramfs.sh`
now builds `rootfs/initramfs/gts9-charger.c` (static aarch64 musl, built with
the shell.nix clang) into the initramfs; `/init` runs it first when the boot
looks like a charger boot:

- `androidboot.mode=charger` or `androidboot.bootmode=charger`, or any
  `...lpcharge=1` parameter (ABL passes `sec_pon_alarm.lpcharge`,
  `pdic_notifier_module.pdic_param_lpcharge`, ... as 0 on a normal boot);
- `gts9.charger=1` forces it and `gts9.charger=0` disables it (for testing;
  add with `CMDLINE_EXTRA=` when building the bundle).

Behaviour: waits for `/dev/fb0`, runs the same platform suspend/resume cycle
the systemd panel-recovery unit uses (the ANA38407 panel is dead after the
cold-boot hand-off until then), draws a battery gauge with the percentage, and
keeps the panel dark (30 s lit after any power or volume key press).  Hold the power key
for 1.5 s to continue the boot normally (refused below 3 %).  If the charger
stays unplugged for 6 s it powers the tablet off.  If it cannot draw (no
framebuffer) it exits at once and the boot continues, so a broken charging
screen can never stop the tablet from starting.

## What ABL passes for a charger-started boot (measured 2026-09-26)

With the tablet powered off through the desktop's power-key dialog while the
cable stayed plugged in, ABL started it again by itself, and the kernel command
line of that boot differed from a power-key boot in exactly the Samsung
charger-mode parameters:

```
pdic_notifier_module.pdic_param_lpcharge=1 nfc_sec.nfc_param_lpcharge=1
flicker_sensor.flicker_param_lpcharge=1 cpufreq_limit.lpcharge=1
sec-battery.lpcharge=1 max77705_charger.lpcharge=1 max77705-fuelgauge.lpcharge=1
p9320_charger.lpcharge=1 s2miw04_charger.lpcharge=1 cps4038_charger.lpcharge=1
nu1668_charger.lpcharge=1 msm_drm.secdp_param_lpcharge=1 sec_pon_alarm.lpcharge=1
```

A power-key boot has the same parameters with `=0` and lacks the extra
`cpufreq_limit`/`sec-battery`/`max77705*`/`p9320*`/... entries.  There is no
`androidboot.mode=charger` in this ABL's line, so `/init` keys on
`lpcharge=1` (the `androidboot.*` patterns stay as harmless extras).

`/init` also appends `charger_mode=<0|1> <cmdline>` to
`/var/log/gts9-boot-cmdlines.log` on the rootfs for every boot, so the marker
can be re-checked after later ABL/firmware changes.

Power-key note: with full userspace running, `systemd-logind` owns the power
key (it opens the shutdown dialog / powers off).  In the initramfs nothing else
reads it, so `gts9-charger` sees the raw key events.

## Sleep-drain knobs

`scripts/build-android-v4-bundle.sh` takes `CMDLINE_DROP` and `CMDLINE_EXTRA`.
The bring-up flags `clk_ignore_unused pd_ignore_unused regulator_ignore_unused
initcall_debug` are still on by default; drop them one at a time on hardware.

## Sleep-drain findings (2026-09-26, tablet on a PC USB port)

- Suspend itself works and charges: a 9.5-minute `rtcwake -m mem` on a 500 mA
  USB port raised the pack from 8 to 9 % (OCV +2 mV), same order as awake with
  the panel off.  So "charges slowly while sleeping" is not a charger-limit
  issue on plain USB; the PD/PPS path (contract surviving suspend) still needs a
  real charger to check.
- `/sys/kernel/debug/qcom_stats` across suspend: `apss` and `adsp` counts grow
  (CPU cluster and ADSP sleep), but `aosd`, `cxsd` and `ddr` are 0 for the whole
  uptime.  The SoC never reaches XO shutdown / CX collapse / DDR self-refresh,
  so a suspended tablet burns far more than it should.  With the cable
  attached the DWC3 (`usb30_prim_gdsc`), PCIe0 (`pcie_0_gdsc`) and display
  (`mdss_gdsc`) keep `cx`/`mmcx` voted at corner 256, and `gcc`/`gpu_cc`
  `sync_state()` stays pending on `3d6a000.gmu`.  Which of those votes survive
  on battery is unmeasured: run
  `/usr/libexec/gts9wifi-sleep-audit 600` over Wi-Fi, unplug the cable, wait,
  and read `summary.txt` and `held-before-suspend.txt` in its output directory.
- Wi-Fi power save (`iw dev wlp1s0 set power_save on`) saves about 40 mA while
  idle with the panel off; left off (the udev rule) because of the throughput
  collapse it caused.

## Charging-screen implementation notes (hard-won, 2026-09-26)

Getting the off-mode screen reliable on hardware took several flash cycles; the
causes, in the order they were found:

- **No key events at all in the initramfs.**  `evdev` is `=m`, so there is no
  `/dev/input/event*` until udev loads it on the real system.  The initramfs has
  no modprobe: `scripts/build-real-root-initramfs.sh` carries `evdev.ko`
  (decompressed from `out/kernel/modules-out`) and `/init` `insmod`s it.  The
  kernel config fragment now sets `CONFIG_INPUT_EVDEV=y`, after which the
  carried module is unnecessary (the script only warns if it is missing).
- **fbcon repaints over the gauge.**  Every unblank makes the framebuffer console
  redraw its text buffer (console text with the first lines wiped), which looked
  like "kernel logs over the gauge" and "the gauge needs several presses to come
  back".  `/init` unbinds the frame-buffer vtconsole
  (`/sys/class/vtconsole/vtcon*/bind`) for the whole session and rebinds it before
  the normal boot continues.  The console log level is muted too.  Do **not** use
  `KDSETMODE KD_GRAPHICS` on tty0: that hung the tablet mid-draw.
- **The gauge must not wait for the SD card.**  Charger boots showed the SD root
  late or not at all; an earlier build that mounted it first sat in `/init`
  forever.  The screen now starts before the root is looked for.  A background
  job mounts the SD card aside (`/mnt/logroot`) when it appears and keeps
  `var/log/gts9-charger.log` (the app's timestamped step log) and
  `gts9-charger-dmesg.log` there, then unmounts it before the normal mount.
- **Powering off is implemented by the app** (charger absent for 6 s), so a
  test that unplugs the cable is expected to power the tablet off.
- With full userspace running, `systemd-logind` owns the power key; a test of the
  app from a booted system needs `systemd-inhibit
  --what=handle-power-key:handle-suspend-key:idle:sleep`.

### Debug network (opt-in)

`CMDLINE_EXTRA="gts9.debugnet=1"` when building the bundle makes `/init` bring
up the kernel USB gadget network (`usb0`, 172.16.42.1) and start `telnetd -l
/bin/sh` on it, killed before `switch_root`.  It is an unauthenticated root shell
on the USB link: **never ship it in a normal image**.  From the PC:
`(printf 'cmd\n'; sleep 3) | nc 172.16.42.1 23` (the initramfs busybox only has
symlinks for some applets; call others as `/bin/busybox <applet>`).  This is how
the missing `/dev/input` was found: `cat /tmp/gts9-charger.log` and `ls
/dev/input` from the stuck tablet.

### Building and flashing

```
BUILD_OUT=out/x nix-shell shell.nix --run 'bash scripts/build-real-root-initramfs.sh'
BUILD_OUT=out/x USE_REAL_ROOT=1 BRINGUP_RAMDISK=out/x/real-root-initramfs.cpio.gz \
    nix-shell shell.nix --run 'bash scripts/build-android-v4-bundle.sh'
# only init_boot + vendor_boot change when just the initramfs does
```
Follow the pre-flash checklist in `docs/boot-strategy.md` (fresh
`scripts/backup-boot-set.sh` backup first).
