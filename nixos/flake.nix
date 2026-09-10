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
  #   nix run   ./nixos#deploy -- ...   # scripts/deploy-nixos-rootfs.sh
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
      # to the flake).
      #
      # ../out/kernel is the exception: it is .gitignore'd (a build
      # artifact of ../scripts/build-mainline-kernel.sh), so the flake
      # cannot see it purely. It is read via an absolute path, which makes
      # every build here REQUIRE `--impure`. This is deliberate and
      # matches the root flake's honesty about the Fedora rootfs not being
      # hermetic -- see ./README.md. Point X716B_REPO_ROOT at the checkout
      # (defaults to $PWD, i.e. run nix from the repo root).
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
          ./modules/x716b-hardware.nix
          ./modules/rootfs-image.nix
          ./modules/x716b-desktop.nix
          ./modules/x716b-device.nix
        ];
      };

      # Build products are all aarch64 derivations (realised on the dev
      # host through its registered aarch64 binfmt); expose the same set
      # under both systems so `nix build ./nixos#rootfs-tar` works from
      # x86_64.
      products = {
        toplevel = x716b.config.system.build.toplevel;
        rootfs-image = x716b.config.system.build.rootfsImage;
        rootfs-tar = (pkgsFor target).callPackage ./packages/rootfs-tar.nix {
          toplevel = x716b.config.system.build.toplevel;
        };
      };
    in
    {
      nixosConfigurations.x716b = x716b;

      packages.${target} = products;
      packages.${host} = products;

      apps.${host}.deploy = {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${host}.writeShellScript "deploy-nixos-rootfs" ''
          exec bash "$(git rev-parse --show-toplevel)/scripts/deploy-nixos-rootfs.sh" "$@"
        '');
      };

      # Expose the package set for debugging: nix eval ./nixos#pkgs.x716b...
      legacyPackages.${target} = pkgsFor target;
      legacyPackages.${host} = pkgsFor host;
    };
}
