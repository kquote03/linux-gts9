# Portable .tar.gz of the whole NixOS closure, matching the contract of
# the Fedora builder's x716b-fedora-*-rootfs.tar.gz: unpack it onto a
# formatted partition (ext4, label X716B_ROOT) and the Android bundle's
# switch_root initramfs boots it via /sbin/init. Used by the microSD
# deploy path (scripts/deploy-nixos-rootfs.sh sd ...).
{ lib, stdenvNoCC, buildPackages, gnutar, gzip, coreutils, toplevel, etcNixos }:

let
  closureInfo = buildPackages.closureInfo { rootPaths = [ toplevel ]; };
in
stdenvNoCC.mkDerivation {
  pname = "x716b-nixos-rootfs-tar";
  version = "1";

  nativeBuildInputs = [ gnutar gzip coreutils ];

  dontUnpack = true;

  buildCommand = ''
    root=$PWD/root
    mkdir -p $root/nix/store $root/sbin $root/bin \
             $root/nix/var/nix/profiles $root/nix/var/nix/gcroots \
             $root/proc $root/sys $root/dev $root/run $root/tmp $root/var $root/etc

    # The store closure, path by path.
    while read -r p; do cp -a "$p" "$root/nix/store/"; done < ${closureInfo}/store-paths
    cp ${closureInfo}/registration $root/nix/store/.reginfo

    ln -s ${toplevel} $root/nix/var/nix/profiles/system-1-link
    ln -s system-1-link $root/nix/var/nix/profiles/system
    ln -s /nix/var/nix/profiles/system $root/nix/var/nix/gcroots/booted-system
    ln -s /nix/var/nix/profiles/system/init $root/sbin/init
    ln -s /nix/var/nix/profiles/system/sw/bin/sh $root/bin/sh

    mkdir -p $root/etc/nixos
    cp -a ${etcNixos}/. $root/etc/nixos/
    chmod -R u+w $root/etc/nixos

    tar --numeric-owner --sort=name \
      --owner=0 --group=0 \
      --mtime='@1' \
      -C $root -cf - . | gzip -9n > $out
  '';

  meta.platforms = [ "aarch64-linux" ];
}
