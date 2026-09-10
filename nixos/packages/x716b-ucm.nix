# nixpkgs' alsa-ucm-conf ucm2 tree with this device's GTS9 UCM2 configs
# (rootfs/overlay-common/usr/share/alsa/ucm2/**) merged in. Point ALSA at
# it with ALSA_CONFIG_UCM2=<this>/share/alsa/ucm2. A plain merge -- no
# rebuild of alsa-ucm-conf or anything downstream of it.
{ lib, stdenvNoCC, alsaUcmConf, rootfsSrc }:

stdenvNoCC.mkDerivation {
  pname = "x716b-alsa-ucm2";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dst=$out/share/alsa/ucm2
    mkdir -p "$dst"
    cp -a ${alsaUcmConf}/share/alsa/ucm2/. "$dst"/
    chmod -R u+w "$dst"
    cp -a ${rootfsSrc}/overlay-common/usr/share/alsa/ucm2/. "$dst"/
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
