# iio-sensor-proxy 3.9 built with -Dssc-support=enabled + libssc, so it
# can read the accel/ALS the SSC serves on this SoC (the kernel-IIO-only
# upstream/nixpkgs build sees nothing here). Same source + the
# notify-slow-sensor-discovery patch the Fedora builder uses.
{ lib, stdenv, fetchzip, meson, ninja, pkg-config, glib, gtk-doc, systemd
, libgudev, polkit, umockdev, libssc, specsSrc }:

stdenv.mkDerivation rec {
  pname = "iio-sensor-proxy";
  version = "3.9-ssc";

  src = fetchzip {
    url = "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/3.9/iio-sensor-proxy-3.9.tar.gz";
    sha256 = "044vhkbivpb84cs9zddbri36s4960dqp1z9m2dh0id4hkqbgipyq";
  };

  patches = [
    (specsSrc + "/iio-sensor-proxy-libssc/patches/notify-slow-sensor-discovery.patch")
  ];

  nativeBuildInputs = [ meson ninja pkg-config gtk-doc ];
  buildInputs = [ glib systemd libgudev polkit umockdev libssc ];

  mesonFlags = [
    "-Dssc-support=enabled"
    "-Dsystemdsystemunitdir=${placeholder "out"}/lib/systemd/system"
    "-Dudevrulesdir=${placeholder "out"}/lib/udev/rules.d"
  ];

  # meson resolves the polkit .policy install dir from
  # polkit-gobject-1.pc's `policydir` -- an absolute path inside polkit's
  # own (read-only) store output. Redirect it under $out via pkg-config's
  # per-variable override.
  env.PKG_CONFIG_POLKIT_GOBJECT_1_POLICYDIR = "${placeholder "out"}/share/polkit-1/actions";

  meta = {
    description = "IIO sensor proxy with Qualcomm SSC support";
    homepage = "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
}
