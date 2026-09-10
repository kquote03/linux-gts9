# The 3 udev rules from rootfs/overlay-common/usr/lib/udev/rules.d/,
# packaged for services.udev.packages (which searches
# <pkg>/lib/udev/rules.d/). Init-agnostic. NixOS's udev-rules validator
# rejects absolute program paths that aren't in the store, so the one
# `/usr/bin/iw` call is rewritten to the nixpkgs `iw`.
{ lib, stdenvNoCC, rootfsSrc, iw }:

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
    chmod -R u+w $out/lib/udev/rules.d
    substituteInPlace $out/lib/udev/rules.d/*.rules \
      --replace-quiet /usr/bin/iw ${iw}/bin/iw
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
