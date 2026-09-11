# Raw ext4 image of the whole NixOS closure, label X716B_ROOT, for the
# userdata / twrp-sd deploy targets. A plain package (not a NixOS module,
# unlike the first draft) so it is NOT part of nixosConfigurations.x716b's
# own module list -- the device only needs ./hardware.nix + ./configuration.nix
# to rebuild itself; this and rootfs-tar.nix are purely build-time outputs.
{ lib, pkgs, modulesPath, toplevel, etcNixos }:

let
  populate = ''
    mkdir -p ./files/sbin ./files/bin ./files/nix/var/nix/profiles ./files/nix/var/nix/gcroots
    ln -s ${toplevel} ./files/nix/var/nix/profiles/system-1-link
    ln -s system-1-link ./files/nix/var/nix/profiles/system
    ln -s /nix/var/nix/profiles/system ./files/nix/var/nix/gcroots/booted-system
    ln -s /nix/var/nix/profiles/system/init ./files/sbin/init
    ln -s /nix/var/nix/profiles/system/sw/bin/sh ./files/bin/sh

    # Real, mutable /etc/nixos -- not environment.etc (that would make
    # NixOS's own /etc activation own and reset these files on every
    # rebuild, defeating the point of being user-editable).
    mkdir -p ./files/etc/nixos
    cp -a ${etcNixos}/. ./files/etc/nixos/
    chmod -R u+w ./files/etc/nixos
  '';
in
pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
  storePaths = [ toplevel ];
  volumeLabel = "X716B_ROOT";
  populateImageCommands = populate;
  compressImage = false;
}
