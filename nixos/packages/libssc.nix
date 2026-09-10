# libssc 0.4.4 -- Qualcomm SSC (Snapdragon Sensor Core) client library
# used by iio-sensor-proxy's -Dssc-support=enabled build. Same source the
# Fedora builder and the postmarketOS port before it use
# (scripts/build-fedora-rootfs.sh).
{ lib, stdenv, fetchzip, meson, ninja, pkg-config, protobuf, protobufc
, glib, libqmi, qrtr }:

stdenv.mkDerivation rec {
  pname = "libssc";
  version = "0.4.4";

  src = fetchzip {
    url = "https://codeberg.org/DylanVanAssche/libssc/archive/v${version}.tar.gz";
    sha256 = "0wpj9ckdp7w86p8wqll890qmky00hvcf2bw9824x9kh6v4v39l0b";
  };

  nativeBuildInputs = [ meson ninja pkg-config protobuf ];
  # Propagated: libssc.pc lists these in Requires:, so any consumer
  # (iio-sensor-proxy's -Dssc-support build) needs their cflags too.
  propagatedBuildInputs = [ glib libqmi protobufc ];
  buildInputs = [ qrtr ];

  mesonFlags = [ (lib.mesonBool "b_lto" true) ];

  meta = {
    description = "Qualcomm SSC (Snapdragon Sensor Core) client library";
    homepage = "https://codeberg.org/DylanVanAssche/libssc";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
