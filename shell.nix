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

    # Buildroot (scripts/fetch-buildroot.sh, scripts/build-buildroot-rootfs.sh)
    # -- a separate, smaller "prove the display works" Weston rootfs, not the
    # debootstrap-based Phase 4 Ubuntu rootfs above. Buildroot builds its own
    # internal toolchain/musl and downloads its own package sources under its
    # own output/ tree; wget is the one host tool it needs that nothing above
    # already provides (its own downloader defaults to wget). `file` is also
    # required by Buildroot's own dependency check (patched in
    # scripts/build-buildroot-rootfs.sh to accept it via PATH rather than
    # NixOS's nonexistent /usr/bin/file) -- listed here so the shell is
    # self-contained rather than relying on it happening to already be on
    # PATH from the host's own NixOS config.
    wget
    file
  ];

  shellHook = ''
    export ARCH=arm64
    export LLVM=1
    export CROSS_COMPILE_AARCH64=aarch64-unknown-linux-gnu-

    # Kbuild's LLVM=1 also points HOSTCC/HOSTCXX at bare clang-unwrapped,
    # which has no default header search paths on NixOS and fails building
    # host tools like scripts/kconfig/fixdep ("sys/types.h file not found").
    # Force host tool builds through the properly-wrapped native cc/c++
    # instead -- confirmed this is the actual fix by reproducing the
    # failure and testing the override directly, not guessing.
    export HOSTCC=cc
    export HOSTCXX=c++

    # llvm.clang-unwrapped being on PATH at all (needed for Kbuild's own
    # LLVM=1 clang/lld discovery, see above) means its bundled bare `cpp`
    # binary -- not a properly-wrapped one with NixOS's default header
    # search paths -- is what plain `cpp`/autoconf's preprocessor probe
    # finds on PATH ahead of the real one, independent of HOSTCC/HOSTCXX
    # (those only cover Kbuild's own invocations, not every other
    # program's own toolchain detection). Exporting CPP fixes this for any
    # tool that consults it directly (confirmed: a bare `cpp` invocation
    # with a real header include fails without this, succeeds with it).
    # Buildroot's own host-package builds needed a second, more targeted
    # fix on top of this -- see scripts/build-buildroot-rootfs.sh's
    # HOSTCPP override and its comment for why this export alone wasn't
    # enough there.
    export CPP="cc -E"

    # bare clang-unwrapped doesn't auto-find its own resource-dir (builtin
    # headers like arm_neon.h) on NixOS -- nixpkgs splits it into a separate
    # ".lib" output rather than the same prefix as the clang binary. Found
    # this by reproducing a real build failure ("arm_neon.h file not
    # found" compiling lib/crc/crc64-neon.o) and confirming the header
    # lives under llvmPackages_19.clang-unwrapped.lib instead. -resource-dir
    # alone isn't enough under the kernel's -nostdinc flag though (verified
    # in isolation: -nostdinc drops resource-dir/include from the search
    # path entirely, not just the normal system dirs) -- needs an explicit
    # -isystem pointing at the same directory too.
    clangResDir="${llvm.clang-unwrapped.lib}/lib/clang/${pkgs.lib.versions.major llvm.clang-unwrapped.version}"
    export KCFLAGS="-resource-dir=$clangResDir -isystem $clangResDir/include"

    # Fully static aarch64 busybox for the bring-up initramfs
    # (scripts/build-bringup-ramdisk.sh) -- the default dynamically-linked
    # busybox references a Nix store path as its ELF interpreter, which
    # won't exist on-device. Not added to `packages`/PATH since it's a
    # foreign-arch binary, not a host tool.
    export BUSYBOX_AARCH64_STATIC=${pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.busybox}/bin/busybox

    echo "linux-tabs9-port build shell ready."
    echo "  clang:  $(${llvm.clang-unwrapped}/bin/clang --version | head -1)"
    echo "  adb:    $(adb --version | head -1)"
  '';
}
