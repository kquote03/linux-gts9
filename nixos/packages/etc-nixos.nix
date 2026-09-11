# Stages a real, mutable copy of this flake onto /etc/nixos of the
# deployed image: flake.nix + lock, hardware.nix, configuration.nix,
# overlay.nix, packages/*.nix, and vendor/{rootfs,specs,...} (real
# copies of repoPaths' content -- the device has no repo checkout for
# ./vendor/*'s symlinks to resolve against, so those can't be copied
# as-is; repoPaths is passed through directly instead, each already a
# proper standalone store path, sidestepping the symlinks entirely).
#
# NOT shipped via environment.etc: that would make NixOS's own /etc
# activation own and reset these files on every `nixos-rebuild switch`,
# defeating the point of being user-editable. This package is copied in
# at image-populate time instead (see rootfs-image.nix / rootfs-tar.nix),
# landing as ordinary writable files nothing in the module system
# touches again.
{ lib, stdenvNoCC, files, packagesDir, repoPaths }:

stdenvNoCC.mkDerivation {
  pname = "x716b-etc-nixos";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/packages $out/vendor

    install -Dm644 ${files.flakeNix} $out/flake.nix
    install -Dm644 ${files.flakeLock} $out/flake.lock
    install -Dm644 ${files.hardware} $out/hardware.nix
    install -Dm644 ${files.configuration} $out/configuration.nix
    install -Dm644 ${files.overlay} $out/overlay.nix
    install -Dm644 ${files.readme} $out/README.md

    cp -a ${packagesDir}/. $out/packages/

    cp -a ${repoPaths.rootfs} $out/vendor/rootfs
    cp -a ${repoPaths.specs} $out/vendor/specs
    cp -a ${repoPaths.vendorFirmware} $out/vendor/vendor-firmware-dump
    cp -a ${repoPaths.buildrootFw} $out/vendor/buildroot-firmware-overlay

    # Only the slice ./packages/x716b-kernel.nix actually reads -- NOT
    # the whole out/kernel (2.6 GB of vmlinux/.tmp_vmlinux*/build-
    # intermediate cruft alongside the real payload).
    mkdir -p $out/vendor/kernel/arch/arm64/boot/dts/qcom \
             $out/vendor/kernel/include/config
    cp ${repoPaths.outKernel}/.config $out/vendor/kernel/.config
    cp ${repoPaths.outKernel}/include/config/kernel.release \
       $out/vendor/kernel/include/config/kernel.release
    cp ${repoPaths.outKernel}/arch/arm64/boot/Image \
       $out/vendor/kernel/arch/arm64/boot/Image
    cp ${repoPaths.outKernel}/System.map $out/vendor/kernel/System.map
    if [ -f ${repoPaths.outKernel}/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb ]; then
      cp ${repoPaths.outKernel}/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb \
         $out/vendor/kernel/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb
    fi
    cp -a ${repoPaths.outKernel}/modules-out $out/vendor/kernel/modules-out
    chmod -R u+w $out

    # This checkout's flake.nix points repoPaths at ../rootfs, ../specs,
    # etc. (one level above nixos/) and resolves the kernel impurely via
    # repoRoot/X716B_REPO_ROOT (../out/kernel is .gitignore'd, so Nix's
    # git-tree filtering makes it impure in THIS checkout regardless of
    # how the path is spelled). None of that makes sense relative to
    # /etc/nixos/flake.nix on the device -- there is no ../rootfs there,
    # and no enclosing git repo to need --impure for. Repoint all five at
    # the real copies staged alongside at ./vendor/*, which resolve
    # purely because /etc/nixos sits outside any git repository at all.
    substituteInPlace $out/flake.nix \
      --replace-fail 'rootfs = ../rootfs;' 'rootfs = ./vendor/rootfs;' \
      --replace-fail 'specs = ../specs;' 'specs = ./vendor/specs;' \
      --replace-fail 'vendorFirmware = ../vendor-firmware-dump;' 'vendorFirmware = ./vendor/vendor-firmware-dump;' \
      --replace-fail 'buildrootFw = ../buildroot/firmware-overlay;' 'buildrootFw = ./vendor/buildroot-firmware-overlay;' \
      --replace-fail 'path = "''${repoRoot}/out/kernel";' 'path = ./vendor/kernel;'

    runHook postInstall
  '';

  meta.platforms = lib.platforms.all;
}
