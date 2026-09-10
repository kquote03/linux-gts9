# HexagonFS payload (userspace Hexagon FastRPC skel libraries) staged at
# the -R root the hexagonrpcd sensorspd unit expects:
#   /usr/share/qcom/sm8550/Samsung/gts9-5g/dsp
# Extracted from this device's own dsp partition by
# ../../scripts/extract-vendor-firmware.sh.
{ lib, stdenvNoCC, vendorFirmware }:

stdenvNoCC.mkDerivation {
  pname = "x716b-hexagonfs";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dst=$out/share/qcom/sm8550/Samsung/gts9-5g/dsp
    mkdir -p $dst
    if [ -d ${vendorFirmware}/hexagonfs/dsp/adsp ]; then
      cp -a ${vendorFirmware}/hexagonfs/dsp/adsp/. $dst/
    else
      echo "WARN: ${vendorFirmware}/hexagonfs/dsp/adsp missing" >&2
    fi
    runHook postInstall
  '';

  meta.license = lib.licenses.unfree;
  meta.platforms = [ "aarch64-linux" ];
}
