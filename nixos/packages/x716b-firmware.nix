# One merged /lib/firmware tree for the SM-X716B: the exact files this
# repo already extracted / staged for every other rootfs builder --
#   ../../buildroot/firmware-overlay/  : ath11k WCN6855 hw2.1, qca BT +
#       hpnv21* NVRAM, and THIS device's factory WiFi calibration (the
#       repo default -- see ../../docs/wifi-samsung-calibration.md)
#   ../../vendor-firmware-dump/firmware/         : Adreno GPU blobs
#   ../../vendor-firmware-dump/firmware/qcom-sm8550/ : ADSP PIL (adsp*.mdt
#       + segments), all four PDR service-registry .jsn, and the
#       AudioReach topology binary
# Consumed via hardware.firmware.
{ lib, stdenvNoCC, vendorFirmware, buildrootFw }:

stdenvNoCC.mkDerivation {
  pname = "x716b-firmware";
  version = "1";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    fw=$out/lib/firmware
    mkdir -p $fw/qcom/sm8550 $fw/qca

    # WiFi/BT + calibration overlay (whole tree).
    if [ -d ${buildrootFw}/lib/firmware ]; then
      cp -a ${buildrootFw}/lib/firmware/. $fw/
    else
      echo "WARN: ${buildrootFw}/lib/firmware missing -- run scripts/fetch-ath11k-firmware.sh" >&2
    fi

    # Adreno GPU (same allowlist as scripts/build-fedora-rootfs.sh).
    for f in a740_zap.mdt a740_zap.b00 a740_zap.b01 a740_zap.b02 \
             a740_sqe.fw gmu_gen70200.bin; do
      if [ -f ${vendorFirmware}/firmware/$f ]; then
        install -Dm644 ${vendorFirmware}/firmware/$f $fw/qcom/$f
      else
        echo "WARN: GPU firmware ${vendorFirmware}/firmware/$f not found" >&2
      fi
    done

    # ADSP PIL + PDR .jsn + AudioReach topology (whole staged dir --
    # missing any one PDR .jsn breaks pd-mapper and the sound card).
    if [ -n "$(ls -A ${vendorFirmware}/firmware/qcom-sm8550 2>/dev/null)" ]; then
      cp -a ${vendorFirmware}/firmware/qcom-sm8550/. $fw/qcom/sm8550/
    else
      echo "WARN: ${vendorFirmware}/firmware/qcom-sm8550 empty -- ADSP will not probe" >&2
    fi

    runHook postInstall
  '';

  # These are Samsung/Qualcomm-signed device blobs.
  meta.license = lib.licenses.unfree;
  meta.platforms = [ "aarch64-linux" ];
}
