# nixpkgs overlay for the SM-X716B NixOS rootfs. Exposes everything
# device-specific under pkgs.x716b.*.
#
# It deliberately does NOT globally override alsa-ucm-conf or
# iio-sensor-proxy: overriding a package that deep in the audio/desktop
# closure forces the whole subtree to rebuild from source, which on a
# RAM-limited machine building aarch64 under emulation means an OOM. The
# UCM tree is shipped as its own package (pkgs.x716b.ucm, wired via
# ALSA_CONFIG_UCM2) and the SSC iio-sensor-proxy is used only where the
# device module places it.
{ repoPaths }:

final: prev:
let
  inherit (final) callPackage;
in
{
  x716b = rec {
    libssc = callPackage ./packages/libssc.nix { };
    pd-mapper = callPackage ./packages/pd-mapper.nix { };
    hexagonrpcd = callPackage ./packages/hexagonrpcd.nix {
      specsSrc = repoPaths.specs;
    };
    iio-sensor-proxy-ssc = callPackage ./packages/iio-sensor-proxy-ssc.nix {
      inherit libssc;
      specsSrc = repoPaths.specs;
    };

    firmware = callPackage ./packages/x716b-firmware.nix {
      vendorFirmware = repoPaths.vendorFirmware;
      buildrootFw = repoPaths.buildrootFw;
    };

    hexagonfs = callPackage ./packages/x716b-hexagonfs.nix {
      vendorFirmware = repoPaths.vendorFirmware;
    };

    libexec = callPackage ./packages/x716b-libexec.nix {
      rootfsSrc = repoPaths.rootfs;
    };

    udevRules = callPackage ./packages/x716b-udev-rules.nix {
      rootfsSrc = repoPaths.rootfs;
    };

    # nixpkgs' stock alsa-ucm-conf tree + this device's GTS9 UCM2 files
    # merged into one directory, for ALSA_CONFIG_UCM2. No rebuild of
    # alsa-ucm-conf itself.
    ucm = callPackage ./packages/x716b-ucm.nix {
      alsaUcmConf = prev.alsa-ucm-conf;
      rootfsSrc = repoPaths.rootfs;
    };

    kernel = callPackage ./packages/x716b-kernel.nix {
      outKernel = repoPaths.outKernel;
    };
  };
}
