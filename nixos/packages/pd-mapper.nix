# pd-mapper 1.1 -- Qualcomm protection-domain mapper. Parses the PDR
# service-registry JSONs staged in /lib/firmware/qcom/sm8550 and answers
# QMI PD-locate requests; without it pd-mapper exits "no pd maps
# available" and the sound card sticks on "error getting cpu dai name"
# (root-caused live -- see scripts/extract-vendor-firmware.sh).
{ lib, stdenv, fetchzip, pkg-config, qrtr, xz }:

stdenv.mkDerivation rec {
  pname = "pd-mapper";
  version = "1.1";

  src = fetchzip {
    url = "https://github.com/andersson/pd-mapper/archive/refs/tags/v${version}.tar.gz";
    sha256 = "1xvls2h3fdnvzvis8h5axlf0qsnll75d1x76998x6dlfhbdwv7r3";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ qrtr xz ];

  makeFlags = [ "prefix=${placeholder "out"}" ];
  installFlags = [ "prefix=${placeholder "out"}" ];

  meta = {
    description = "Qualcomm protection-domain mapper";
    homepage = "https://github.com/andersson/pd-mapper";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
    mainProgram = "pd-mapper";
  };
}
