# NixOS aarch64 rootfs for the SM-X716B

A second, standalone flake (the repo root `../flake.nix` is the toolchain
/ kernel / boot-bundle pipeline and is unchanged). This one builds a full
**NixOS aarch64** userland carrying every device fix this port has —
the same overlay the Fedora builder applies
(`../rootfs/overlay-common` + `../rootfs/overlay-systemd`), translated to
idiomatic NixOS modules, plus the source-built Qualcomm sensor/ADSP stack
(libssc / pd-mapper / hexagonrpcd / iio-sensor-proxy-SSC), the vendor
firmware, and the prebuilt kernel module tree.

Desktop: **KDE Plasma 6** (Wayland). First-boot user `x716b` / password
`x716b` (root too).

## What it does and does not build

- **Does**: the aarch64 NixOS system, the device modules, the custom
  packages, a portable rootfs **tarball** and a raw **ext4 image**, and a
  deploy script.
- **Does not**: build the kernel or the Android boot bundle. It *consumes*
  `../out/kernel` (`Image` + `modules-out`, built by
  `../scripts/build-mainline-kernel.sh`) and `../out/android/*.img`. Build
  those first, from the repo root, exactly as today.

## Not hermetic — requires `--impure`

`../out/kernel` is `.gitignore`d (a build artifact), so this flake reads
it by absolute path and every build here needs `--impure`. Point
`X716B_REPO_ROOT` at the checkout, or just run `nix` from the repo root
(the default is `$PWD`). The NixOS closure itself is reproducible; the
kernel it is pinned against is only as reproducible as that script's
output. Same honesty as the root flake's note about the Fedora rootfs.

The module tree shipped in `/lib/modules/<release>` is the exact
`modules_install` output of that same kernel build — it MUST match the
`Image` in the `boot` partition (`CONFIG_MODULE_SIG=y` + `MODVERSIONS`).
Build the boot bundle and this rootfs from the same `../out/kernel`.

## Build

```sh
# from the repo root, after `nix run .#build-kernel` (root flake)
nix build --impure ./nixos#rootfs-tar      # -> result -> *.tar.gz  (microSD path)
nix build --impure ./nixos#rootfs-image    # -> result -> ext4 .img (userdata path)
```

Most of the closure comes from `cache.nixos.org`; the custom packages and
anything not cached for aarch64 build locally through the host's
registered `aarch64-linux` binfmt (slow the first time).

## Deploy

Both targets carry the rootfs with filesystem label `X716B_ROOT`, which
`../scripts/build-real-root-initramfs.sh`'s `/init` finds automatically.
The boot bundle is flashed separately with
`../scripts/flash-boot-set.sh`.

```sh
# microSD (from this PC; stock Android untouched)
scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device sd DEV=/dev/sdX

# internal userdata (tablet in TWRP; ERASES stock Android /data)
scripts/deploy-nixos-rootfs.sh --i-understand-this-writes-to-the-device userdata
```

## Layout

| file | role |
|---|---|
| `flake.nix` | inputs (nixpkgs pinned to the root flake's commit), outputs |
| `overlay.nix` | nixpkgs overlay: `pkgs.x716b.*` + `iio-sensor-proxy`/`alsa-ucm-conf` overrides |
| `modules/x716b-hardware.nix` | prebuilt kernel + modules, no bootloader/initrd, rootfs by label, vendor firmware |
| `modules/rootfs-image.nix` | `system.build.rootfsImage` (raw ext4, label `X716B_ROOT`) |
| `modules/x716b-desktop.nix` | Plasma 6, PipeWire, NetworkManager, users, ssh |
| `modules/x716b-device.nix` | the overlay translation — `gts9wifi-*` units, vendor mounts, zram/journald/lid, ADSP chain (manual-start) |
| `packages/*` | `libssc`, `pd-mapper`, `hexagonrpcd`, `iio-sensor-proxy-ssc`, `x716b-firmware`, `x716b-hexagonfs`, `x716b-libexec`, `x716b-udev-rules`, `x716b-kernel`, `rootfs-tar` |

See `../docs/distro-porting.md` for the overlay contract this implements
and `../docs/boot-strategy.md` for the boot chain.
