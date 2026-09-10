# nixpkgs overlay for the SM-X716B NixOS rootfs. Exposes everything
# device-specific under pkgs.x716b.* plus a couple of upstream-package
# overrides the device needs (iio-sensor-proxy with SSC support, an
# alsa-ucm-conf carrying the GTS9 tree).
{ repoPaths }:

final: prev:
let
  inherit (final) lib callPackage;

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

    # HexagonFS payload staged at the -R path the hexagonrpcd sensorspd
    # drop-in expects (/usr/share/qcom/sm8550/Samsung/gts9-5g/dsp).
    hexagonfs = callPackage ./packages/x716b-hexagonfs.nix {
      vendorFirmware = repoPaths.vendorFirmware;
    };

    # The gts9wifi-* /libexec scripts (init-agnostic ones from
    # overlay-common + the systemctl-calling ones from overlay-systemd),
    # installed to $out/libexec so units can reference an absolute path.
    libexec = callPackage ./packages/x716b-libexec.nix {
      rootfsSrc = repoPaths.rootfs;
    };

    # The 3 udev rules from overlay-common, as a services.udev.packages entry.
    udevRules = callPackage ./packages/x716b-udev-rules.nix {
      rootfsSrc = repoPaths.rootfs;
    };

    # Prebuilt kernel + module tree from ../out/kernel, wrapped as a Nix
    # kernel package so boot.kernelPackages / system.modulesTree are coherent.
    kernel = callPackage ./packages/x716b-kernel.nix {
      outKernel = repoPaths.outKernel;
    };
  };
in
{
  inherit x716b;

  # iio-sensor-proxy with -Dssc-support=enabled (kernel-IIO-only upstream
  # build cannot see the SSC-served accel/ALS on this SoC).
  iio-sensor-proxy = x716b.iio-sensor-proxy-ssc;

  # alsa-ucm-conf carrying this device's UCM2 tree from overlay-common.
  alsa-ucm-conf = prev.alsa-ucm-conf.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp -rv ${repoPaths.rootfs}/overlay-common/usr/share/alsa/ucm2/. \
        $out/share/alsa/ucm2/
    '';
  });
}
