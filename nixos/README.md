# NixOS aarch64 rootfs for the SM-X716B

A second, standalone flake (the repo root `../flake.nix` is the toolchain
/ kernel / boot-bundle pipeline and is unchanged). This one builds a full
**NixOS aarch64** userland carrying every device fix this port has —
the same overlay the Fedora builder applies
(`../rootfs/overlay-common` + `../rootfs/overlay-systemd`), translated to
idiomatic NixOS, plus the source-built Qualcomm sensor/ADSP stack
(libssc / pd-mapper / hexagonrpcd / iio-sensor-proxy-SSC), the vendor
firmware, and the prebuilt kernel module tree.

Desktop: **KDE Plasma 6** (Wayland), Bluetooth, the graphics-tablet KCM,
Krita, Firefox. First-boot user `x716b` / password `x716b` (root too).

**Confirmed booting on real hardware** (2026-09-11): SSH, systemd, the
desktop stack and all of the fixes below verified live over the tablet's
own WiFi.

## Hardware vs. configuration — and it's genuinely yours to edit

This flake is split by concern, and the split is shipped onto the device
itself so you can actually use it there:

- **`hardware.nix`** — the non-negotiable device plumbing: the prebuilt
  kernel + module tree, no bootloader/initrd (ABL boots the Android
  `boot` partition directly), rootfs-by-label, vendor firmware/partition
  mounts, and the translated `gts9wifi-*` overlay (ADSP/sensor/USB-gadget
  units). Don't edit this unless you know the hardware reason behind a
  line.
- **`configuration.nix`** — everything user-facing: desktop choice,
  installed packages, Bluetooth, networking, users, locale. Edit this
  freely.
- **`flake.nix`** wires `nixosConfigurations.x716b = nixosSystem {
  modules = [ ./hardware.nix ./configuration.nix ]; }` and carries the
  custom-package overlay (all of which is hardware bring-up).

All of this — `flake.nix`, `flake.lock`, `hardware.nix`,
`configuration.nix`, `overlay.nix`, `packages/*.nix`, and a `vendor/`
directory holding real copies of everything those packages need
(`rootfs/`, `specs/`, `vendor-firmware-dump/`,
`buildroot/firmware-overlay/`, and the kernel's `.config` +
`modules-out/`) — is staged as **real, mutable files** at `/etc/nixos/`
on the deployed image (see `packages/etc-nixos.nix`). Not via
`environment.etc`: that would make NixOS's own `/etc` activation own and
overwrite these files on every rebuild, defeating the point.

**On the tablet:**

```sh
sudo nano /etc/nixos/configuration.nix   # or hardware.nix, if you mean it
sudo nixos-rebuild switch                # auto-detects /etc/nixos/flake.nix
```

This evaluates **purely** — no `--impure`, no network needed just to
resolve `<nixpkgs>` — because `/etc/nixos` sits outside any git
repository, unlike this checkout (see "Not hermetic" below). Confirmed
live with a throwaway copy of the staged flake outside this repo's git
tree.

## What it does and does not build

- **Does**: the aarch64 NixOS system, the device packages, the
  `/etc/nixos` staging package, a portable rootfs **tarball** and a raw
  **ext4 image**, and a deploy script.
- **Does not**: build the kernel or the Android boot bundle. It
  *consumes* `../out/kernel` (`Image` + `modules-out`, built by
  `../scripts/build-mainline-kernel.sh`) and `../out/android/*.img`.
  Build those first, from the repo root, exactly as today.

## Not hermetic (from this checkout) — requires `--impure`

`../out/kernel` is `.gitignore`d (a build artifact), so *this checkout's*
flake reads it by absolute path and every build from here needs
`--impure`. Point `X716B_REPO_ROOT` at the checkout, or just run `nix`
from the repo root (the default is `$PWD`). `packages/etc-nixos.nix`
patches the five `repoPaths` lines in the *shipped* copy of `flake.nix`
to point at the real `./vendor/*` copies it stages alongside — which is
why the on-device flake needs none of this. The NixOS closure itself is
reproducible; the kernel it is pinned against is only as reproducible as
that script's output. Same honesty as the root flake's note about the
Fedora rootfs.

The module tree shipped in `/lib/modules/<release>` is the exact
`modules_install` output of that same kernel build — it MUST match the
`Image` in the `boot` partition (`CONFIG_MODULE_SIG=y` + `MODVERSIONS`).
Build the boot bundle and this rootfs from the same `../out/kernel`.

## Build

```sh
# from the repo root, after `nix run .#build-kernel` (root flake)
nix build --impure ./nixos#rootfs-tar      # -> result -> *.tar.gz  (microSD path)
nix build --impure ./nixos#rootfs-image    # -> result -> ext4 .img (userdata / twrp-sd path)
```

Most of the closure comes from `cache.nixos.org`; the custom packages and
anything not cached for aarch64 build locally through the host's
registered `aarch64-linux` binfmt. **Keep an eye on host RAM** if you're
adding packages: overriding something deep in the closure (we hit this
with an early `alsa-ucm-conf` override) forces a mass rebuild under
emulation and can OOM a memory-constrained build host. `nix build
--dry-run` first to see the plan size; `--max-jobs 1` or `2` if it's
large.

## Deploy

All three targets carry the rootfs with filesystem label `X716B_ROOT`,
which `../scripts/build-real-root-initramfs.sh`'s `/init` finds by label
first (falling back to the old `mmcblkXp1` device-node list). The boot
bundle is flashed separately with `../scripts/flash-boot-set.sh`.

```sh
# microSD, written from THIS PC via a card reader (stock Android untouched)
scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device sd DEV=/dev/sdX

# microSD, already seated in the tablet -- streamed over adb with the
# tablet in TWRP (stock Android untouched; erases whatever was on that card)
scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device twrp-sd

# internal userdata (tablet in TWRP; ERASES stock Android /data)
scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device userdata
```

**TWRP's bundled tools have real quirks**, confirmed live and worked
around in the deploy script:

- Its toybox `dd` fails `read error: Bad address` reading stdin (the adb
  pipe) at `bs=1M` or larger — every `adb shell dd` here uses `bs=64k`.
- Its `e2fsprogs` (1.45.4, ~2019) can't even parse the superblock our
  build's modern `mke2fs` writes ("has unsupported feature(s)" — the
  `orphan_file` feature, e2fsprogs 1.46/2021). Not corruption — the
  mainline kernel we boot supports it fine — but it means the deploy
  script does **not** run TWRP's `e2fsck`/`resize2fs` at all;
  `fileSystems."/".autoResize` (`hardware.nix`) grows the filesystem on
  first real boot instead, using the matching e2fsprogs in the NixOS
  closure itself.
- No on-device `e2label` either — the image already carries the
  `X716B_ROOT` label from `packages/rootfs-image.nix`'s `volumeLabel`.

## Bring-up fixes worth knowing about

Found by diagnosing the first real boot live over SSH (`journalctl -u
<unit>`, `systemctl status`), then reproduced/fixed in `hardware.nix`
directly — see that file's comments for the full reasoning on each:

- **`CapabilityBoundingSet=""` doesn't mean "no restriction"** — unlike
  `RestrictAddressFamilies`/`SystemCallFilter`, an empty
  `CapabilityBoundingSet=` is the *empty* capability set (deny
  everything), not "unrestricted". Broke `chronyd` outright
  (`chown()` on `/run/chrony` failing as root). `~` is the "full set"
  token.
- **NixOS services get a minimal default `PATH`** — no `util-linux`
  (`mount`), no `dtc` (`fdtget`/`fdtput`). The ported `gts9wifi-*` scripts
  that call these need an explicit `path = [ ... ];`.
- **A drop-in `ExecStart=` without a leading `""` appends, not
  replaces** — two `ExecStart=` lines on a `Type=simple` service is
  invalid ("bad unit file setting"). Use `ExecStart = [ "" "<cmd>" ];`.
- **No `/lib` at all** — anything that scans the FHS `/lib/firmware`
  path directly (not via the kernel's own `request_firmware()`, which
  finds `hardware.firmware` fine) sees nothing. A `systemd.tmpfiles.rules`
  symlink papers over this for tools that need it.
- **The kernel is missing a netfilter match** the default firewall
  ruleset needs (`xt_pkttype`) — `firewall.service` fails outright rather
  than degrading. `networking.firewall.enable` defaults to `false` in
  `hardware.nix` (override in `configuration.nix` once the kernel gains
  `CONFIG_NETFILTER_XT_MATCH_PKTTYPE`).
- **`pd-mapper` needs PDR `.jsn` registry files this checkout doesn't
  have** — `vendor-firmware-dump/firmware/qcom-sm8550/` never got them
  extracted (a pre-existing gap shared with the Fedora rootfs, not a
  NixOS-specific bug). Re-run `../scripts/extract-vendor-firmware.sh`
  against the device's own `apnhlos`/`dsp` partitions to fix it for both
  builders.

## Layout

| file | role |
|---|---|
| `flake.nix` | inputs (nixpkgs pinned to the root flake's commit), `nixosConfigurations.x716b`, build outputs |
| `hardware.nix` | device support — kernel/modules/bootloader/fs, firmware, udev, vendor mounts, the ported `gts9wifi-*` units |
| `configuration.nix` | Plasma 6, Bluetooth, packages, networking, users — edit this one |
| `overlay.nix` | nixpkgs overlay exposing `pkgs.x716b.*` |
| `packages/*` | `libssc`, `pd-mapper`, `hexagonrpcd`, `iio-sensor-proxy-ssc`, `x716b-firmware`, `x716b-hexagonfs`, `x716b-ucm`, `x716b-libexec`, `x716b-udev-rules`, `x716b-kernel`, `etc-nixos`, `rootfs-tar`, `rootfs-image` |

See `../docs/distro-porting.md` for the overlay contract this implements
and `../docs/boot-strategy.md` for the boot chain.
