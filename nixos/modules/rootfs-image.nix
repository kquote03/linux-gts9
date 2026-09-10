# system.build.rootfsImage -- a raw ext4 image of the whole NixOS closure,
# label X716B_ROOT, grown to fill its partition on first boot
# (fileSystems."/".autoResize). The device is booted by the Android
# bundle's busybox initramfs, which does `switch_root /mnt/newroot
# /sbin/init`, so the image provides /sbin/init -> the system profile's
# stage-2 init and the /nix/var/nix/profiles/system generation link.
{ config, lib, pkgs, modulesPath, ... }:

let
  rootPaths = [ config.system.build.toplevel ];

  # Commands run against ./files (the future /) before mkfs.
  populate = ''
    mkdir -p ./files/sbin ./files/bin ./files/nix/var/nix/profiles ./files/nix/var/nix/gcroots
    ln -s ${config.system.build.toplevel} ./files/nix/var/nix/profiles/system-1-link
    ln -s system-1-link ./files/nix/var/nix/profiles/system
    ln -s /nix/var/nix/profiles/system ./files/nix/var/nix/gcroots/booted-system
    ln -s /nix/var/nix/profiles/system/init ./files/sbin/init
    ln -s /nix/var/nix/profiles/system/sw/bin/sh ./files/bin/sh
  '';
in
{
  system.build.rootfsImage = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = rootPaths;
    volumeLabel = "X716B_ROOT";
    populateImageCommands = populate;
    compressImage = false;
  };
}
