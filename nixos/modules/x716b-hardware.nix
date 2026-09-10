# SM-X716B hardware plumbing: pin NixOS to this repo's prebuilt kernel +
# module tree, disable the bootloader/initrd (ABL boots the Android `boot`
# partition directly -- see ../../docs/boot-strategy.md), and mount the
# rootfs by label so one image serves both the microSD and the
# userdata-partition deploy targets.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Keep the profile minimal -- this is an appliance rootfs, not an
    # installer.
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  ############################################################
  # Kernel + modules: the prebuilt tree from ../../out/kernel #
  ############################################################

  boot.kernelPackages = pkgs.linuxPackagesFor pkgs.x716b.kernel;

  # This port builds everything it needs into the Image or ships it as a
  # matching prebuilt module; NixOS should not try to (cross-)build any
  # kernel module of its own.
  nix.settings.system-features = lib.mkDefault [ ];
  boot.extraModulePackages = lib.mkForce [ ];

  #############################################
  # No NixOS-managed bootloader and no initrd #
  #############################################

  # ABL loads /dev/block/by-name/boot (the Android boot-image-v4 bundle
  # from ../../scripts/build-android-v4-bundle.sh); NixOS's stage-1 and
  # any bootloader are dead weight here.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;
  # Escape hatch so `nixos-rebuild switch` / activation don't assert on a
  # missing bootloader installer.
  system.build.installBootLoader = lib.mkForce "${pkgs.coreutils}/bin/true";

  # The Android bundle carries its own busybox switch_root initramfs
  # (../../scripts/build-real-root-initramfs.sh). NixOS's own initrd is
  # never loaded, so don't spend a build on it.
  boot.initrd.enable = false;

  ##########################
  # Root + vendor mounts   #
  ##########################

  # Labelled so ../../scripts/build-real-root-initramfs.sh's /init finds
  # it whether it lives on the microSD partition or on `userdata`.
  fileSystems."/" = {
    device = "/dev/disk/by-label/X716B_ROOT";
    fsType = "ext4";
    autoResize = true;
  };
  boot.growPartition = true;

  # Direct partlabel mounts for the Qualcomm firmware/persist partitions
  # (the preset only ever enabled these three; the full /vendor erofs
  # needs a dynamic-partition mapper this port has not implemented).
  fileSystems."/mnt/vendor/persist" = {
    device = "/dev/disk/by-partlabel/persist";
    fsType = "ext4";
    options = [ "ro" "nofail" "x-systemd.device-timeout=5s" ];
  };
  fileSystems."/mnt/vendor/dsp" = {
    device = "/dev/disk/by-partlabel/dsp";
    fsType = "ext4";
    options = [ "ro" "nofail" "x-systemd.device-timeout=5s" ];
  };
  fileSystems."/mnt/vendor/firmware_mnt" = {
    device = "/dev/disk/by-partlabel/modem";
    fsType = "vfat";
    options = [ "ro" "nofail" "x-systemd.device-timeout=5s" ];
  };

  # The real kernel command line lives in the Android bundle; nothing to
  # add here.
  boot.kernelParams = [ ];

  # Vendor firmware blobs (WiFi/BT/GPU/ADSP + PDR registry + AudioReach
  # topology), merged into one /lib/firmware search tree.
  hardware.firmware = [ pkgs.x716b.firmware ];
  hardware.enableRedistributableFirmware = true;

  # Serial console fallback on the USB gadget tty. NOT systemd's
  # serial-getty@.service template: it carries BindsTo=dev-ttyGS0.device,
  # never satisfied for this gadget tty (the Fedora build documents the
  # same dead-getty symptom) -- a plain unit with no device dependency.
  systemd.services."x716b-serial-getty" = {
    description = "Serial getty on ttyGS0 (USB gadget console, no device-unit dependency)";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "-${pkgs.util-linux}/sbin/agetty --keep-baud 115200 ttyGS0 $TERM";
      Type = "idle";
      Restart = "always";
      RestartSec = 1;
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyGS0";
      TTYReset = true;
      TTYVHangup = true;
    };
  };

  system.stateVersion = "26.05";
}
