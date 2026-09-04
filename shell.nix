{ pkgs ? import <nixpkgs> {} }:

let
  llvm = pkgs.llvmPackages_19;
in
pkgs.mkShell {
  packages = with pkgs; [
    # Mainline kernel + uniLoader build (both use ARCH=arm64/aarch64, LLVM=1 or
    # CROSS_COMPILE=aarch64-linux-gnu-)
    coreutils
    bash
    bc
    bison
    llvm.clang-unwrapped
    llvm.bintools
    pkgsCross.aarch64-multiplatform.stdenv.cc # aarch64-linux-gnu- GNU cross toolchain, for uniLoader's CROSS_COMPILE path
    cpio
    dtc
    elfutils
    flex
    gawk
    gnumake
    gnused
    findutils
    gnutar
    kmod
    ncurses
    openssl
    pahole
    perl
    python3
    pkg-config
    rsync
    util-linux
    zlib
    zstd
    lz4

    # Android boot image tooling (mkbootimg/avbtool vendored under
    # third_party/android-tools/ — these just provide the python3 interpreter
    # and any native deps they need, e.g. pycryptodome pulled in separately if
    # needed)

    # Rootfs / image pipeline
    debootstrap # mmdebstrap is not packaged in this nixpkgs snapshot; debootstrap
                # is the documented fallback (see docs/hardware-facts.md)
    qemu-user # qemu-aarch64 user-mode emulation, for binfmt-based cross-arch
              # chroot work during rootfs builds (qemu_full pulls in a huge
              # unrelated dependency tree — ceph/arrow/glusterfs/azure-sdk —
              # and isn't needed here)
    gptfdisk # sgdisk
    parted
    multipath-tools # provides kpartx
    e2fsprogs
    dosfstools
    xz
    zip
    unzip

    # Device interaction
    android-tools # adb (fastboot is not usable on this device family)
  ];

  shellHook = ''
    export ARCH=arm64
    export LLVM=1
    export CROSS_COMPILE_AARCH64=aarch64-unknown-linux-gnu-

    echo "linux-tabs9-port build shell ready."
    echo "  clang:  $(${llvm.clang-unwrapped}/bin/clang --version | head -1)"
    echo "  adb:    $(adb --version | head -1)"
  '';
}
