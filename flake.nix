{
  # Reproducible build environment for the linux-tabs9-port project --
  # replaces shell.nix (kept, unused, for anyone still invoking `nix-shell`
  # directly; this flake is now the primary entry point).
  #
  # ## What "reproducible" means here, honestly
  #
  # `flake.lock` pins nixpkgs to an exact commit, so every tool this
  # project's scripts depend on (clang, the aarch64 cross toolchain, dnf5,
  # the static qemu-aarch64 interpreter, dracut, mkbootimg/avbtool's own
  # python3, ...) resolves to the exact same derivation on any machine that
  # builds from this flake -- that part is genuinely hermetic.
  #
  # The Fedora *rootfs* build (`apps.build-rootfs`, scripts/build-fedora-
  # rootfs.sh) is NOT hermetic in the same sense: `dnf5` resolves package
  # content against Fedora's own live repos over the network, same as
  # gts9wifi-fedora's own upstream reference does via its GitHub Actions
  # runners (see docs/porting-log.md's gts9wifi-fedora pivot entry) --
  # neither this project nor the reference achieves bit-for-bit rootfs
  # reproducibility, and pretending otherwise would be worse than being
  # explicit about it. What this flake *does* guarantee reproducibly is the
  # toolchain used to build/flash everything, and the exact scripts/config
  # (kernel patches, DTS, rootfs package lists) checked into this repo.
  #
  # ## Usage
  #
  #   nix develop                    # interactive shell, replaces `nix-shell`
  #   nix run .#build-kernel         # scripts/build-mainline-kernel.sh
  #   nix run .#build-rootfs         # scripts/build-fedora-rootfs.sh
  #   nix run .#build-bundle         # scripts/build-android-v4-bundle.sh
  #   nix run .#flash -- <args>      # scripts/flash-boot-set.sh
  #
  # Each `apps.*` entry runs the real script from this checkout (not a
  # copy baked into the Nix store), so editing a script takes effect
  # immediately without re-entering the shell -- matching how this project
  # has always iterated.

  description = "Samsung Galaxy Tab S9 5G (SM-X716B) mainline Linux port -- build environment";

  # Pinned to the exact commit this dev machine's own running NixOS system
  # is built from (confirmed via the system derivation's own name suffix,
  # `nixos-system-*-26.05.20260817.0dd31db`) -- guarantees every package
  # below resolves to an already-built, cached derivation instead of
  # forcing a from-source build (confirmed the hard way: pinning to a
  # different, arbitrary nixos-unstable HEAD commit first made `dnf5`
  # rebuild from source and fail outright, `make: *** [Makefile:146: all]
  # Error 2`, since that commit's dnf5 derivation had no cached substitute).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/0dd31db7e6dbf9ce05697c4545f6fe01accec994";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux"; # the only host architecture this project builds on;
                                # every target artifact is cross-built for aarch64.
      pkgs = import nixpkgs { inherit system; };
      llvm = pkgs.llvmPackages_19;

      # Same environment variables shell.nix's shellHook set -- needed by
      # both `nix develop` (via devShells.default.shellHook) and every
      # `apps.*` wrapper below (via mkApp's own env block), so defined once
      # here rather than duplicated.
      clangResDir = "${llvm.clang-unwrapped.lib}/lib/clang/${pkgs.lib.versions.major llvm.clang-unwrapped.version}";
      commonEnv = {
        ARCH = "arm64";
        LLVM = "1";
        CROSS_COMPILE_AARCH64 = "aarch64-unknown-linux-gnu-";
        HOSTCC = "cc";
        HOSTCXX = "c++";
        CPP = "cc -E";
        KCFLAGS = "-resource-dir=${clangResDir} -isystem ${clangResDir}/include";
        BUSYBOX_AARCH64_STATIC = "${pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.busybox}/bin/busybox";

        # Confirmed live (this flake, first `nix develop` test): merely
        # listing `pkgsStatic.qemu-user` in `packages` is NOT enough --
        # `which qemu-aarch64` still resolved to the plain, dynamically-
        # linked `qemu-user` package's own binary instead (some other
        # package in this list pulls that in transitively, shadowing it
        # on PATH; confirmed via `ldd` showing real glibc/x86_64 shared
        # libs, not the genuinely static build). An explicit env var,
        # same pattern as BUSYBOX_AARCH64_STATIC above, sidesteps the
        # PATH ambiguity entirely -- scripts/build-fedora-rootfs.sh reads
        # this instead of doing its own `nix-build -E '...'` lookup.
        QEMU_AARCH64_STATIC = "${pkgs.pkgsStatic.qemu-user}/bin/qemu-aarch64";
      };

      devPackages = with pkgs; [
        # Mainline kernel + uniLoader build (both use ARCH=arm64/aarch64,
        # LLVM=1 or CROSS_COMPILE=aarch64-linux-gnu-)
        coreutils bash bc bison
        llvm.clang-unwrapped llvm.bintools
        pkgsCross.aarch64-multiplatform.stdenv.cc
        cpio dtc elfutils flex gawk gnumake gnused findutils gnutar kmod
        ncurses openssl pahole perl python3 pkg-config rsync util-linux
        zlib zstd lz4

        # Rootfs / image pipeline
        debootstrap # superseded by the Fedora rootfs pivot for the actual
                    # distro rootfs, but scripts/build-ubuntu-rootfs.sh stays
                    # in the repo unused (this project's convention for
                    # superseded work, e.g. uniLoader) -- kept available.
        dnf5 # scripts/build-fedora-rootfs.sh's real package manager.
        # NOT `pkgsStatic.qemu-user` in this list -- see commonEnv's
        # QEMU_AARCH64_STATIC above for why it's referenced by explicit
        # path (an env var) instead of being added to PATH.
        dracut # boot/dracut-based initramfs, adopted from gts9wifi-fedora
               # in the Session 9 pivot (real dracut, not this project's
               # earlier bespoke busybox initramfs).
        rpm # rpmbuild -- not currently used (this project builds the
            # kernel via its own pipeline, not gts9wifi-fedora's
            # kernel.spec), kept available if that's revisited.
        gptfdisk parted multipath-tools e2fsprogs dosfstools xz zip unzip

        # Device interaction
        android-tools # adb (fastboot is not usable on this device family)

        # Buildroot (scripts/fetch-buildroot.sh, scripts/build-buildroot-rootfs.sh)
        wget file
      ];

      shellHookScript = ''
        echo "linux-tabs9-port build shell ready."
        echo "  clang:  $(${llvm.clang-unwrapped}/bin/clang --version | head -1)"
        echo "  adb:    $(adb --version | head -1)"
      '';

      # mkApp: wrap a real script from this checkout with the same PATH/
      # env every build script needs, without copying the script itself
      # into the Nix store -- so editing scripts/*.sh takes effect
      # immediately, matching this project's existing iteration pattern.
      mkApp = name: scriptRelPath: {
        type = "app";
        program = toString (pkgs.writeShellScript name (
          ''
            set -euo pipefail
            repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
          ''
          + pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (k: v: "export ${k}=${pkgs.lib.escapeShellArg v}\n") commonEnv)
          + ''
            export PATH="${pkgs.lib.makeBinPath devPackages}:$PATH"
            exec bash "$repo_root/${scriptRelPath}" "$@"
          ''
        ));
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = devPackages;
        shellHook = (pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (k: v: "export ${k}=${pkgs.lib.escapeShellArg v}\n") commonEnv)) + shellHookScript;
      };

      apps.${system} = {
        build-kernel = mkApp "build-kernel" "scripts/build-mainline-kernel.sh";
        build-rootfs = mkApp "build-rootfs" "scripts/build-fedora-rootfs.sh";
        build-bundle = mkApp "build-bundle" "scripts/build-android-v4-bundle.sh";
        flash = mkApp "flash" "scripts/flash-boot-set.sh";
      };
    };
}
