# The gts9wifi-* helper scripts from rootfs/overlay-common/usr/libexec/
# and rootfs/overlay-systemd/usr/libexec/, installed to $out/libexec so
# the ported systemd units reference an absolute store path instead of a
# hard-coded /usr/libexec. Scripts are kept as-is (they encode real
# hardware workarounds -- see docs/distro-porting.md); only shebangs are
# patched and the one inter-script /usr/libexec reference is rewritten to
# $out.
{ lib, stdenvNoCC, rootfsSrc, python3, coreutils }:

stdenvNoCC.mkDerivation {
  pname = "x716b-libexec";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec
    for d in overlay-common overlay-systemd; do
      if [ -d ${rootfsSrc}/$d/usr/libexec ]; then
        for f in ${rootfsSrc}/$d/usr/libexec/gts9wifi-*; do
          install -Dm755 "$f" "$out/libexec/$(basename "$f")"
        done
      fi
    done

    # gts9wifi-panel-coldboot-recover invokes gts9wifi-usb-host-resume by
    # absolute /usr/libexec path -- point it at our own tree.
    substituteInPlace $out/libexec/* \
      --replace-quiet /usr/libexec/gts9wifi- $out/libexec/gts9wifi-

    patchShebangs $out/libexec
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
