# Porting the device overlay to a new distro / init system

This project's kernel, DTS, and firmware-staging pipeline are shared across
every rootfs target. The *userspace device overlay* — the systemd units,
udev rules, ALSA UCM configs, and small hardware-workaround scripts this
port has accumulated — used to live entirely under `rootfs/overlay/` and
was, in practice, only ever applied by `scripts/build-fedora-rootfs.sh`.
That meant real, hard-won fixes (pd-mapper's PDR registry files, the
AudioReach topology reuse, per-amp channel routing) were only reachable
from Fedora, even though nothing about them is Fedora-specific. This repo
carries five rootfs builders (`build-fedora-rootfs.sh`, `-alpine-`,
`-buildroot-`, `-ubuntu-`, plus the bring-up ramdisk); the split below
exists so the next one doesn't silently miss this work.

## The split

**`rootfs/overlay-common/`** — apply this from *every* rootfs builder,
unconditionally. Nothing in it assumes systemd (or any other specific init
system):

- `usr/share/alsa/ucm2/**` — ALSA UCM2 configs. Standard `alsa-lib`/
  `alsa-ucm-conf` tree, same path on every distro that ships ALSA.
  *Something* still needs to trigger UCM's `BootSequence` for a card
  (PipeWire's ALSA-UCM integration, PulseAudio's `module-alsa-card`, or a
  manual `alsaucm` call) — this project hasn't confirmed that happens
  automatically on a minimal rootfs, which is why `gts9wifi-audio-init`
  (below) exists as a belt-and-suspenders fallback.
- `usr/lib/udev/rules.d/**` — udev rules. udev (or a fork like Alpine's
  eudev) runs independently of the init system.
- `usr/share/dbus-1/system-services/**` — D-Bus service activation files.
  Same reasoning: D-Bus doesn't care what PID 1 is.
- `usr/libexec/gts9wifi-*` (most of them) — plain POSIX `/bin/sh` scripts
  with no `systemctl`/`journalctl` calls baked in. Safe to invoke from any
  init system's own hook mechanism.
- `etc/locale.conf`, `etc/machine-info` — plain key=value files; harmless
  even where nothing reads them (`localed`/`hostnamed` are systemd
  components, but these aren't systemd-*only* file formats).

**`rootfs/overlay-systemd/`** — Fedora's own layer, and the reference
implementation for what a new init system's equivalent layer needs to
cover:

- `usr/lib/systemd/system/**`, `usr/lib/systemd/system-preset/**` — unit
  files and the enablement preset.
- `etc/systemd/**` — drop-ins (`*.service.d/`), sleep hooks
  (`system-sleep/`), `journald.conf.d`, `logind.conf.d`.
- `etc/tmpfiles.d/**` — `systemd-tmpfiles`' own convention.
- The 3 `usr/libexec/gts9wifi-*` scripts that call `systemctl` directly
  (`gts9wifi-bt-revive`, `gts9wifi-wait-sensor-proxy`,
  `gts9wifi-sensors-resume`) — these encode systemd-specific *behavior*
  (restarting a named unit), not just systemd-specific *placement*, so
  they don't belong in the common layer even though they're plain shell.

## Porting checklist for a new distro/init system

1. Apply `rootfs/overlay-common/` as-is — no adaptation needed.
2. Write your own `rootfs/overlay-<initsystem>/`, using
   `rootfs/overlay-systemd/` as the thing to translate *from*, not copy:
   - Each `.service`/`.mount`/`.path` unit needs an equivalent start/stop
     hook in your init system (an OpenRC init script, a runit `run` file,
     a BusyBox `inittab`/`rcS` entry, etc.), preserving the same
     `After=`/`Requires=` ordering intent documented in that unit's own
     comments — several of these encode real, hard-won hardware
     workarounds (e.g. `gts9wifi-adsp-boot.service`'s ordering after
     `gts9wifi-panel-coldboot-recover.service`: starting the ADSP
     concurrently with that suspend cycle froze the board outright on
     real hardware).
   - The 3 `systemctl`-calling scripts need their `systemctl restart
     <unit>` calls translated to your init system's own service-restart
     command.
   - `system-sleep/` hooks need your init system's own suspend/resume
     hook mechanism (elogind's own hook directory, a `pm-utils` script,
     etc.) — see `gts9wifi-sensors-resume`'s and
     `gts9wifi-usb-host-resume`'s hook files for what each needs to do at
     `pre`/`post`.
   - The system-preset's enable/disable list documents *why* each unit
     is or isn't auto-started (some are deliberately manual-start-only —
     read those comments before blindly enabling everything).
3. Confirm your rootfs builder copies
   `vendor-firmware-dump/firmware/qcom-sm8550/*` (produced by
   `scripts/extract-vendor-firmware.sh`, which also stages the
   AudioReach topology binary — see that script and
   `scripts/stage-audioreach-topology.sh`) into `/lib/firmware/qcom/
   sm8550/` the same way `build-fedora-rootfs.sh` does. This is pure data,
   not distro-specific at all, but a builder that doesn't know to look
   there will silently ship a device with no ADSP and no sound.
4. Confirm *something* triggers ALSA UCM's `BootSequence` for the sound
   card (see the `overlay-common` note above), or otherwise apply the
   equivalent `amixer cset` calls some other way -- without this the
   card instantiates and streams cleanly but produces no audible sound.

## Current status of the other builders

`build-alpine-rootfs.sh` (OpenRC) and `build-ubuntu-rootfs.sh` (systemd,
same init system as Fedora) predate the ADSP/audio/sensor work entirely
and haven't been revisited since the Fedora pivot — likely stale against
the current kernel config regardless of this split. `build-buildroot-
rootfs.sh` is deliberately minimal (Weston-only, no Mesa/GPU, no attempt
at ADSP/audio/sensors) and isn't a target for this checklist at all. This
split is preparatory, not a claim that any of the three currently work.

## NixOS — the reference non-Fedora port

`nixos/` (a standalone flake) is the worked example of this checklist for
a non-Fedora target. NixOS is also systemd, so step 2's *translation* is
mostly mechanical — each `gts9wifi-*.service` becomes a
`systemd.services.<name>` in `nixos/hardware.nix` with the same
`After=/Before=` intent, `85-gts9wifi.preset` drives `wantedBy` (so the
ADSP chain stays manual-start), and the sleep hooks land in
`/etc/systemd/system-sleep/`. `nixos/hardware.nix` carries all of this
device-specific plumbing; `nixos/configuration.nix` is the separate,
user-facing desktop/package layer (see `nixos/README.md`) — worth
keeping that split for a third distro too, if its packaging supports it.
What's genuinely different and worth copying if you do a third distro:

- The Qualcomm sensor/ADSP stack (`libssc`, `pd-mapper`, `hexagonrpcd`,
  `iio-sensor-proxy`-with-SSC) is packaged from the **same source pins**
  the Fedora builder uses (`nixos/packages/*.nix`) — reuse those pins.
- Firmware (step 3) is one merged `/lib/firmware` derivation
  (`nixos/packages/x716b-firmware.nix`) fed to `hardware.firmware`; the
  HexagonFS `-R` payload is a separate package at
  `/usr/share/qcom/sm8550/Samsung/gts9-5g`.
- The kernel module tree is the prebuilt `out/kernel/modules-out`,
  wrapped as a kernel package so it matches the boot bundle's `Image`
  vermagic — do **not** let the distro build its own kernel.
- Root is found by filesystem **label `X716B_ROOT`**
  (`scripts/build-real-root-initramfs.sh`), so a rootfs image works on
  the microSD or on `userdata` unchanged.

See `nixos/README.md`.
