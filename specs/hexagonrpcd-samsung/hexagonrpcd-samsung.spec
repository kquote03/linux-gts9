# hexagonrpcd with the Samsung sensor-registry patches the gts9wifi port
# needs.  Phase 2 will build this in COPR; phase 1 compiles the same source
# set inline in rootfs/build-rootfs.sh (patches live in patches/).
Name:       hexagonrpcd-samsung
Version:    0.4.0
Release:    1%{?dist}
Summary:    Qualcomm HexagonFS daemon with Samsung sensor registry mapping
License:    GPL-3.0-or-later
URL:        https://github.com/linux-msm/hexagonrpc
Source0:    https://github.com/linux-msm/hexagonrpc/archive/refs/tags/v%{version}.tar.gz

Patch1:     patches/systemd-services.patch
Patch2:     patches/hexagonrpc-large-inbufs.patch
Patch3:     patches/support-samsung-sensor-registry-writes.patch
Patch4:     patches/zz-map-sns-reg-version-at-root.patch

BuildRequires: meson, ninja-build, gcc, pkgconf-pkg-config, systemd-devel

# Sensor userspace data (installed by firmware-samsung-gts9wifi):
# /usr/share/qcom/sm8550/Samsung/gts9wifi/{dsp,sensors}

%description
Userspace FastRPC + HexagonFS daemon talking to the Qualcomm ADSP/SDSP
remoteprocs.  Carries two patches the Galaxy Tab S9 port requires: larger
FastRPC input buffers, and mapping Samsung's sensor registry writes onto the
stock persist partition.

# X716B pivot: Patch4 is this port's own addition, found and verified on
# real X716B hardware (not present in the gts9wifi-fedora reference this
# spec was otherwise copied from). Samsung's SM8550 sensor firmware
# requests "sns_reg_version" via a literal path of "/../sns_reg_version"
# -- the leading "/" makes hexagonfs_openat() start from the daemon's
# real virtual root, and ".." from there is clamped (same as POSIX "/.."),
# so it ends up looking for "sns_reg_version" as a *root-level* child --
# not under persist/sensors/registry like every other registry file, which
# is genuinely unserviceable without this patch regardless of what's on
# disk anywhere else. Confirmed via strace: without it, every open of this
# path fails ENOENT; with it, `read()` returns the real "version=6"
# content from the live persist partition (see zz-map-sns-reg-version-
# at-root.patch's own header for the full path-resolution trace).

%prep
%autosetup -n hexagonrpc-%{version} -p1

%build
%meson -Db_lto=true
%meson_build

%install
%meson_install
install -Dm644 %{_sourcedir}/patches/10-fastrpc.rules \
    %{buildroot}%{_udevrulesdir}/10-fastrpc.rules

%files
%license LICENSE
%{_bindir}/*
%{_udevrulesdir}/10-fastrpc.rules
%{_unitdir}/hexagonrpcd*.service

%changelog
* Sat Aug 29 2026 gts9wifi-fedora port <gts9wifi@example.com> - 0.4.0-1
- Initial spec from the postmarketOS packaging of hexagonrpcd 0.4.0-r5.
