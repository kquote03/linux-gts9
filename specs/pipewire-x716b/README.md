The Fedora builder uses `scripts/build-fedora-camera-spa.sh` to compile the
libcamera SPA plugin from the exact Fedora SRPM matching installed
`pipewire-libs`, prepared with Fedora's downstream patches. It records the
core package, source RPM/hash and libcamera version in
`/usr/share/gts9-camera/spa-build.txt`. Source mirrors must still carry that
exact package; builds fail rather than substituting a newer release.
The plugin is installed enabled (`libspa-libcamera.so`); an earlier leak came
from the old 1.0.5-era plugin. A WirePlumber memory cap drop-in backs it, and a long soak test is still to do.

The helper needs `rpm-build`, a DNF download plugin, Python 3, GCC C++,
Meson, and the camera build dependencies already installed by the Fedora
builder. Set `TMPDIR=/var/tmp` for native tablet builds to avoid the small
`/tmp` tmpfs. Set `DESTDIR` to a scratch directory to collect the plugin and
manifest without changing the active system plugin.

The `patches/` directory is historical and **not applied** by any builder (there is no `series` file): it targets the sibling tablet's
PipeWire 1.0.5-era commit, and must not be applied to current Fedora releases.
In particular, it omits upstream control-pagination fixes
`e5afc939e8d053e3331e401f29bdc9913bf200f0` and
`e770ed42c37f25ae1fa640f44ae109988131100a`. Borrowed frame-buffer descriptors
must remain owned by libcamera. The Ultra-specific transform suppression
also has no measured justification on this tablet.

`python3 test-control-pagination.py PIPEWIRE_SOURCE_DIR` compiles the actual
upstream enumeration function with a fake control map and SPA callbacks.
It checks finite pagination, skipped controls, filters and out-of-range
requests without a camera or streaming. Unsupported source layouts fail
closed rather than silently dropping this build gate.
