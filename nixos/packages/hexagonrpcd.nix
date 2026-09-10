# hexagonrpcd 0.4.0 + the Samsung/port patches from
# ../../specs/hexagonrpcd-samsung/ (ported verbatim from gts9wifi-fedora;
# genuine device-behaviour fixes for Samsung's SM8550 sensor firmware --
# large FastRPC inbufs, sensor-registry writes, root-PD sns-reg version
# mapping, and the systemd units). Same tag + patch set the Fedora
# builder uses.
{ lib, stdenv, fetchzip, meson, ninja, pkg-config, qrtr, specsSrc }:

let
  patchDir = specsSrc + "/hexagonrpcd-samsung/patches";
in
stdenv.mkDerivation rec {
  pname = "hexagonrpcd";
  version = "0.4.0";

  src = fetchzip {
    url = "https://github.com/linux-msm/hexagonrpc/archive/refs/tags/v${version}.tar.gz";
    sha256 = "1wflap1fmxrjh6zrmn2aqmc76w1ba4yczd31kprqanw821fb0biq";
  };

  # Alphabetical, matching the Fedora builder's `for p in .../*.patch`.
  patches = [
    (patchDir + "/hexagonrpc-large-inbufs.patch")
    (patchDir + "/support-samsung-sensor-registry-writes.patch")
    (patchDir + "/systemd-services.patch")
    (patchDir + "/zz-map-sns-reg-version-at-root.patch")
  ];

  nativeBuildInputs = [ meson ninja pkg-config ];
  buildInputs = [ qrtr ];

  mesonFlags = [ (lib.mesonBool "b_lto" true) ];

  postInstall = ''
    install -Dm644 ${patchDir}/10-fastrpc.rules \
      -t $out/lib/udev/rules.d/
  '';

  meta = {
    description = "Hexagon FastRPC daemon (hexagonrpcd) with Samsung SM8550 sensor patches";
    homepage = "https://github.com/linux-msm/hexagonrpc";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
