{
  # Second, standalone flake for this port: builds a full NixOS aarch64
  # rootfs for the Samsung Galaxy Tab S9 5G (SM-X716B), carrying every
  # device fix this repo has accumulated -- the same userspace overlay the
  # Fedora builder applies (rootfs/overlay-common + rootfs/overlay-systemd),
  # translated to idiomatic NixOS, plus the source-built Qualcomm
  # sensor/ADSP stack, the vendor firmware, and the prebuilt kernel module
  # tree.
  #
  # The root ../flake.nix (the toolchain / kernel / boot-bundle pipeline)
  # is unchanged and remains the primary entry point. This flake consumes
  # that pipeline's output (../out/kernel, ../out/android) -- it does NOT
  # build the kernel or the Android boot images. See ./README.md.
  #
  # ## Usage
  #
  #   nix build ./nixos#rootfs-tar      # portable tarball (microSD path)
  #   nix build ./nixos#rootfs-image    # raw ext4 image (userdata path)
  #   nix run   ./nixos#deploy -- ...   # scripts/deploy-rootfs.sh (shared)
  #
  # ## Reproducibility, honestly
  #
  # Same caveat as the root flake's Fedora rootfs: nixpkgs is pinned, so
  # the toolchain and every cached derivation is hermetic, but this build
  # imports two prebuilt, non-Nix artifacts by path -- ../out/kernel
  # (Image + modules, built by ../scripts/build-mainline-kernel.sh) and,
  # for deploy, ../out/android/*.img. The NixOS closure itself is
  # reproducible; the kernel it is pinned against is only as reproducible
  # as that script's output.

  description = "SM-X716B (Galaxy Tab S9 5G) mainline port -- NixOS aarch64 rootfs";

  # Pinned to the exact same commit as ../flake.nix so both flakes share a
  # binary cache and toolchain generation (26.05, ~2026-08-17).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/0dd31db7e6dbf9ce05697c4545f6fe01accec994";

  outputs = { self, nixpkgs }:
    let
      target = "aarch64-linux";
      host = "x86_64-linux";

      # Tracked parent-checkout inputs -- pure relative paths (git-visible
      # to the flake from this checkout).
      #
      # ../out/kernel is the exception: it is .gitignore'd (a build
      # artifact of ../scripts/build-mainline-kernel.sh), so the flake
      # cannot see it purely from THIS checkout. It is read via an
      # absolute path, which makes every build here from this checkout
      # REQUIRE `--impure`. This is deliberate and matches the root
      # flake's honesty about the Fedora rootfs not being hermetic -- see
      # ./README.md. Point X716B_REPO_ROOT at the checkout (defaults to
      # $PWD).
      #
      # ./packages/etc-nixos.nix stages real copies of all five of these
      # onto the device's /etc/nixos/vendor/, and repoints all five
      # lines below at that ./vendor/* copy in the shipped flake.nix --
      # /etc/nixos sits outside any git repository, so those substituted
      # lines resolve purely there, no X716B_REPO_ROOT/--impure needed
      # for on-device rebuilds.
      repoRoot =
        let e = builtins.getEnv "X716B_REPO_ROOT";
        in if e != "" then e else builtins.getEnv "PWD";

      repoPaths = {
        rootfs = ../rootfs;
        specs = ../specs;
        vendorFirmware = ../vendor-firmware-dump;
        buildrootFw = ../buildroot/firmware-overlay;
        outKernel = builtins.path {
          path = "${repoRoot}/out/kernel";
          name = "x716b-out-kernel";
        };
      };

      overlay = import ./overlay.nix { inherit repoPaths; };

      pkgsFor = system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
          config.allowUnfree = true; # vendor firmware blobs
        };

      x716b = nixpkgs.lib.nixosSystem {
        system = target;
        specialArgs = { inherit repoPaths; };
        modules = [
          { nixpkgs.overlays = [ overlay ]; nixpkgs.config.allowUnfree = true; }
          ./hardware.nix # device support -- everything in ./packages/* is hardware bring-up too
          ./configuration.nix # desktop + anything user-customizable
        ];
      };

      # Staged onto the device's /etc/nixos (see ./packages/etc-nixos.nix) so
      # `sudo nixos-rebuild switch` there is self-contained -- a real,
      # editable copy of exactly this flake, not a read-only store symlink.
      etcNixos = (pkgsFor target).callPackage ./packages/etc-nixos.nix {
        files = {
          flakeNix = ./flake.nix;
          flakeLock = ./flake.lock;
          hardware = ./hardware.nix;
          configuration = ./configuration.nix;
          overlay = ./overlay.nix;
          readme = ./README.md;
        };
        packagesDir = ./packages;
        inherit repoPaths;
      };

      # Build products are all aarch64 derivations (realised on the dev
      # host through its registered aarch64 binfmt); expose the same set
      # under both systems so `nix build ./nixos#rootfs-tar` works from
      # x86_64.
      products = {
        toplevel = x716b.config.system.build.toplevel;
        inherit etcNixos;
        rootfs-image = (pkgsFor target).callPackage ./packages/rootfs-image.nix {
          modulesPath = nixpkgs + "/nixos/modules";
          toplevel = x716b.config.system.build.toplevel;
          inherit etcNixos;
        };
        rootfs-tar = (pkgsFor target).callPackage ./packages/rootfs-tar.nix {
          toplevel = x716b.config.system.build.toplevel;
          inherit etcNixos;
        };
      };
    in
    {
      nixosConfigurations.x716b = x716b;

      packages.${target} = products;
      packages.${host} = products;

      # scripts/deploy-rootfs.sh is distro-agnostic (shared with Fedora/
      # Debian) and takes an explicit TAR=/IMG= -- this wrapper is the
      # NixOS-specific convenience of building the right one first and
      # forwarding it, so `nix run ./nixos#deploy -- --i-understand-...
      # twrp-sd` still Just Works without spelling out a nix build first.
      apps.${host}.deploy = {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${host}.writeShellScript "deploy-nixos-rootfs" ''
          set -euo pipefail
          repo_root="$(git rev-parse --show-toplevel)"
          target=""
          for a in "$@"; do
            case "$a" in sd|twrp-sd|userdata) target="$a" ;; esac
          done
          extra=()
          case "$target" in
            sd) extra+=(TAR="$(nix build --impure --no-link --print-out-paths "$repo_root/nixos#rootfs-tar")") ;;
            twrp-sd|userdata) extra+=(IMG="$(nix build --impure --no-link --print-out-paths "$repo_root/nixos#rootfs-image")") ;;
          esac
          exec bash "$repo_root/scripts/deploy-rootfs.sh" "$@" "${extra[@]}"
        '');
      };

      # Expose the package set for debugging: nix eval ./nixos#pkgs.x716b...
      legacyPackages.${target} = pkgsFor target;
      legacyPackages.${host} = pkgsFor host;
    };
}
