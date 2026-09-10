# The 3 udev rules from rootfs/overlay-common/usr/lib/udev/rules.d/,
# packaged for services.udev.packages (which searches
# <pkg>/lib/udev/rules.d/). Init-agnostic -- applied verbatim.
{ lib, stdenvNoCC, rootfsSrc }:

stdenvNoCC.mkDerivation {
  pname = "x716b-udev-rules";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/udev/rules.d
    cp -v ${rootfsSrc}/overlay-common/usr/lib/udev/rules.d/*.rules \
      $out/lib/udev/rules.d/
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
