# Wrap the prebuilt mainline kernel from ../out/kernel (built by
# ../scripts/build-mainline-kernel.sh) as a Nix "kernel" package, just
# enough for `pkgs.linuxPackagesFor` and NixOS's `system.modulesTree` to
# work against it.
#
# The device does NOT boot this -- ABL loads the Android `boot` partition,
# whose kernel Image is baked in by ../scripts/build-android-v4-bundle.sh.
# What matters here is that the module tree shipped in the rootfs
# (/lib/modules/<version>) matches that Image's vermagic
# (CONFIG_MODULE_SIG=y + MODVERSIONS). So this repackages the exact
# modules_install output the same build produced.
# `...` absorbs the extra args NixOS's kernel plumbing passes via
# `kernel.override { features = …; }` -- this prebuilt wrapper has no
# config-driven features to vary.
{ lib, stdenvNoCC, outKernel, ... }:

let
  # ../scripts/build-mainline-kernel.sh writes the release string here and
  # installs modules at modules-out/lib/modules/<release>/.
  release = lib.fileContents (outKernel + "/include/config/kernel.release");

  # Parse the real .config so passthru.config answers NixOS's kernel-config
  # assertions truthfully (many modules assert kernel.config.isEnabled
  # "FOO" behind an mkIf; a stub that always says "no" would trip them).
  configAttrs =
    let
      lines = lib.splitString "\n" (builtins.readFile (outKernel + "/.config"));
      parse = line:
        let m = builtins.match "CONFIG_([[:alnum:]_]+)=(.*)" line;
        in if m == null then null
           else { name = builtins.head m; value = builtins.elemAt m 1; };
    in
    builtins.listToAttrs (builtins.filter (x: x != null) (map parse lines));

  configOf = opt: configAttrs.${opt} or "n";
in
stdenvNoCC.mkDerivation {
  pname = "x716b-kernel-prebuilt";
  version = release;

  src = outKernel;

  dontBuild = true;
  dontConfigure = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/modules/${release} $dev/lib/modules/${release}

    # The image ABL actually runs is assembled by the bundle script; keep
    # a copy here for reference / tooling that expects $out/Image.
    install -Dm644 arch/arm64/boot/Image           $out/Image
    install -Dm644 System.map                       $out/System.map
    install -Dm644 .config                          $out/configfile
    install -Dm644 arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb \
      $out/dtbs/qcom/sm8550-samsung-x716b.dtb || true

    # The real payload: the modules_install + depmod tree.
    cp -a modules-out/lib/modules/${release}/. $out/lib/modules/${release}/

    # NixOS's kmod/modulesTree machinery wants build/ and source/ to be
    # resolvable (or absent) -- drop the dangling symlinks the kernel
    # build leaves pointing at the builder's filesystem.
    rm -f $out/lib/modules/${release}/build $out/lib/modules/${release}/source

    # `dev` output: kbuild tree stub so out-of-tree module builds at least
    # fail loudly rather than mis-detecting. This port builds no OOT
    # modules, so a minimal stub is enough.
    install -Dm644 .config $dev/lib/modules/${release}/build/.config
    install -Dm644 System.map $dev/lib/modules/${release}/build/System.map
    ln -s $dev/lib/modules/${release}/build $out/lib/modules/${release}/build

    runHook postInstall
  '';

  outputs = [ "out" "dev" ];

  passthru = {
    inherit release;
    modDirVersion = release;
    kernelOlder = v: lib.versionOlder release v;
    kernelAtLeast = v: lib.versionAtLeast release v;
    # linuxPackagesFor reads these; this port ships everything built-in or
    # as prebuilt modules, so no config-driven feature gating is needed.
    features = { };
    config = {
      isYes = opt: configOf opt == "y";
      isNo = opt: configOf opt == "n";
      isModule = opt: configOf opt == "m";
      isEnabled = opt: let v = configOf opt; in v == "y" || v == "m";
      isDisabled = opt: configOf opt == "n";
      isSet = opt: configAttrs ? ${opt};
      hasFeature = _: false;
    };
    configfile = outKernel + "/.config";
  };

  meta = {
    description = "Prebuilt mainline kernel + module tree for the SM-X716B (from ../out/kernel)";
    platforms = [ "aarch64-linux" ];
  };
}
