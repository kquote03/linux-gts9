# Downstream patches: what this port carries, why, and how every distro gets them

This port depends on patches and out-of-tree code that upstream projects will
not take as they are: they encode one tablet's wiring, one vendor firmware's
bugs, or workarounds for a board's boot chain. They cannot be left to each
distro's own packaging, so this document is the inventory, and the mechanism
below makes sure every distro builder applies exactly the same set, in the same
order, to the same pinned sources.

If you are porting to a new distro, read [How a distro uses this](#how-a-distro-uses-this)
and [Porting checklist](#porting-checklist) and skip the inventory.

## The mechanism (one source of truth)

| Piece | Where | What it does |
|---|---|---|
| Pinned sources | `specs/sources.lock` | URL and **full git commit** of every upstream source we patch (`NAME_URL`, `NAME_COMMIT`, `NAME_SERIES`). Commits, not tags or tarball hashes: they survive moved tags and changes in forge archive compression, and the fetch helper refuses to continue if the checkout is anywhere else. |
| Patch series | `specs/<component>/series` + `specs/<component>/patches/` | Ordered list of patch files (one per line, `#` comments). The order is the single definition of "the patch set". |
| Shared helpers | `scripts/lib/downstream.sh` | `ds_fetch` (pinned checkout + verification), `ds_apply_series` (GNU `patch -p1`, dry-run first, names the offending patch on failure), `ds_prepare` (both). Needs only bash, git and GNU patch. |
| Shared builder | `scripts/build-downstream-userland.sh` | Fetches, patches, builds and installs the userland components with the same flags on any distro. Run inside the target rootfs (or chroot) as root after the distro's build dependencies are installed. Records provenance in `<prefix>/share/gts9-userland/<component>.txt` (URL, commit, series digest). |
| Reproducibility test | `scripts/test-downstream-patches.sh` | Fetches every pinned source, verifies it, applies every series, and fails on any patch that does not apply or is not listed in a series. No build dependencies, so it is CI-friendly. Run it after touching a patch, a series or `sources.lock`. |
| Kernel side | `scripts/build-mainline-kernel.sh`, `kernel/patches/`, `kernel/drivers/`, `kernel/dts/` | One kernel build for every distro (a distro only installs its modules and firmware). Pinned by `scripts/fetch-mainline.sh`; patches are applied with idempotent marker checks. The v4l2loopback module it builds also uses `sources.lock` and a series. |

Rules:

- A patch that is not in a `series` file is never applied. The test fails on
  orphans. `specs/pipewire-x716b/patches/` is the one deliberate exception (see
  below) and says so in its README.
- Distro builders must not carry their own copy of a version, URL, patch list
  or meson flag. They install build dependencies, call the shared builder, and
  do distro-specific steps (rpmdb entries, users, packaging).
- Adding a patch: put the file in `specs/<component>/patches/`, append its name
  to `series`, run `scripts/test-downstream-patches.sh`, and add a row below.
  NixOS picks the change up from the same `series` file
  (`nixos/packages/series.nix`).
- Bumping a pin: change the commit in `sources.lock`, run the test; patches that
  no longer apply must be rebased before anything else.

## Userland patches

Applied by `scripts/build-downstream-userland.sh` (Fedora, Debian) or the
equivalent Nix packages, from `specs/<component>/series`.

### libcamera (`specs/libcamera-x716b/`, pin `62d4bfc45079`, v0.7.2+53; patches 0001-0008)

Built with `--buildtype=release`; meson's default is `debug` (`-O0`), which made
the CPU software ISP several times slower (rear camera ~3.75 fps at `-O0`,
~30 fps release). Installs `tuning/hi1337-gts9.yaml` for the software IPA.

| Patch | What and why | Upstream outlook |
|---|---|---|
| `0001-libipa-add-hynix-hi1337-hi847-gain-helpers` | Gain/black-level helper for the Hynix HI1337 (this tablet) and HI847: without it the software IPA treats the raw gain register as linear and AGC/AWB converge wrongly. | Generic sensor helper; could be sent upstream once a sensor properties entry and an upstream driver exist. Our sensor driver is out of tree, so not yet. |
| `0002-simple-software-autofocus` | Contrast-detection autofocus in the software IPA, driving the DW9808 lens through the pipeline. | A feature that needs an upstream design discussion; unlikely as written. |
| `0003-software-isp-preserve-full-field-of-view` | Letterbox instead of cropping when a client asks for a different aspect ratio than the sensor. | Changes default behaviour; unlikely. |
| `0004-simple-reset-qcom-camss-links-before-configure` | The SM8550 CAMSS routes all sensors through shared CSID/VFE pads; discovery leaves one path enabled and the next camera fails with `EBUSY`. Resets the shared links before selecting a camera. | Pipeline/board workaround; unlikely. |
| `0005-simple-drop-metadata-wait-for-cancelled-output-buffers` | Requests whose software-ISP output is cancelled at `stop()` waited forever for metadata, so `PipelineHandler::stop()` hit `ASSERT(queuedRequests_.empty())` and aborted (WirePlumber and GNOME Camera died on every camera switch). | **A genuine generic bug** (upstream master has the same code). Worth reporting and sending upstream; carried until then. Not yet done. |
| `0006-software-isp-dont-queue-work-to-a-stopped-worker` | `SoftwareIsp::stop()` calls `ipa_->stop()`, whose synchronous IPC spins a nested event loop; a captured frame arriving there is queued to the just-stopped debayer worker and run by the next `start()` on freed buffers (SIGSEGV; fast rear/front switching). | **A genuine generic bug**, same status as 0005. |
| `0007-simple-ipa-retrigger-autofocus-on-scene-change` | After locking, the autofocus only rescanned when the focus score dropped, which misses a subject moving away (a lens focused near blurs everything, so the score stays low). Compares the luminance histogram and score with a reference taken after the lock and rescans once a changed scene settles. Thresholds are untuned first guesses; metrics are logged at debug level. | Builds on 0002 and shares its outlook: unlikely upstream. |
| `0008-simple-ipa-exposure-controls` | The software AGC exposed no controls. Adds `AeEnable`, `ExposureTime`, `AnalogueGain` and `ExposureValue` (manual exposure, and compensation by shifting the AGC's brightness target). Used by `gts9-camera` (`docs/camera-controls.md`). | Newer upstream libcamera moved the software AGC to libipa's shared AGC, which brings its own controls; this patch would be dropped when the pin moves past that. |

### hexagonrpcd (`specs/hexagonrpcd-samsung/`, pin v0.4.0 `23a69640bf10`)

Plus `patches/10-fastrpc.rules` (udev: `fastrpc-*` nodes owned by the `fastrpc`
user), installed by the shared builder. Its units are relocated from
`<libdir>/systemd/system` to `/usr/lib/systemd/system`.

| Patch | What and why | Upstream outlook |
|---|---|---|
| `hexagonrpc-large-inbufs` | FastRPC listener protocol gaps that kill the sensors listener once Samsung's SM8550 sensor firmware starts its registry sync (large input buffers, extended methods, keep listening after an error). | Firmware-behaviour specific; unlikely. |
| `support-samsung-sensor-registry-writes` | Samsung's sensor firmware expects `/mnt/vendor/persist/sensors/registry` to be writable (`fopen("w")`, `rename`); maps it to the HexagonFS prefix and adds `fopen/fwrite/frename`. | Vendor-firmware specific; unlikely. |
| `systemd-services` | Adds systemd units. **Backport** of upstream commit `c4109b45`; drop it when the pin moves past that commit. | Already upstream. |
| `zz-map-sns-reg-version-at-root` | Maps `sns_reg_version` at the HexagonFS root, where Samsung's firmware looks for it. | Vendor-firmware specific; unlikely. |

### iio-sensor-proxy (`specs/iio-sensor-proxy-libssc/`, pin 3.9 `0085ddf8ecb1`)

Built with `-Dssc-support=enabled` against libssc (build libssc first).

| Patch | What and why | Upstream outlook |
|---|---|---|
| `notify-slow-sensor-discovery` | SSC discovery takes tens of seconds; clients that cached `HasAccelerometer=false` never got an update. Broadcasts the property set after discovery. | Reasonable for upstream (SSC support is upstream); worth sending. |
| `start-polling-claimed-while-starting` | mutter claims the accelerometer ~15 ms after the proxy owns its name, before SSC discovery registers it, so polling never started and auto-rotate never worked. | Same. |

### libssc and pd-mapper (no patches)

Not packaged by the target distros, so built from the pinned commits by the shared
builder (`libssc` v0.4.4, `pd-mapper` v1.1).

### v4l2loopback (`specs/v4l2loopback-x716b/`, out-of-tree kernel module)

Built and signed by `scripts/build-mainline-kernel.sh` against this exact
kernel (not DKMS in the rootfs, so the module ABI and signing key match).

| Patch | What and why | Upstream outlook |
|---|---|---|
| `0001-backward-compatible-client-usage-event` | Emit/accept both client-usage event ids so the v4l2-relayd we ship still works. | Compatibility shim; no. |
| `0002-fix-buffer-queue-management` | Don't pre-populate the output queue on `REQBUFS` (violates V4L2; GStreamer's `v4l2sink` aborts). | A real fix; carried from the Ubuntu S9 Ultra port. Could be upstreamed. |
| `0003-preserve-output-queue-for-capture` | A capture client's `REQBUFS` must not clear the producer's queued buffers. | Same. |

### v4l2-relayd (`specs/v4l2-relayd-x716b/`, pin `9c4f7312feb9`, Ubuntu packaging)

Relays PipeWire camera nodes onto v4l2loopback devices for V4L2-only
applications. Shipped, but its service is **disabled by default**: GNOME Camera
and Firefox use the PipeWire portal directly.

| Patch | What and why | Upstream outlook |
|---|---|---|
| `0001-recreate-input-after-stream-error` | All logical cameras share one CAMSS/ISP path: serialize inputs, recreate the input after a stream error. | Tied to this hardware; no. |
| `0002-preempt-active-camera-on-handover` | Applications open the newly selected camera before closing the previous one; debounce probes and let the new client take the shared ISP. | Same. |

### PipeWire libcamera SPA plugin (distro-specific, `specs/pipewire-x716b/`)

The plugin has to match the distro's own PipeWire, so it is **not** built by the
shared builder. Fedora builds it from the installed `pipewire-libs` SRPM with
Fedora's own patches (`scripts/build-fedora-camera-spa.sh`; the build fails
rather than substituting another release) and installs it **enabled**; a
WirePlumber memory cap (`rootfs/overlay-systemd/usr/lib/systemd/user/wireplumber.service.d/`)
backs it. `specs/pipewire-x716b/patches/` is historical (1.0.5-era, from the Ubuntu
port), has no `series`, and is **not applied** by any builder; its README
explains why.

Another distro needs: PipeWire built with `-Dlibcamera=enabled` against the
libcamera above, a plugin recent enough to contain the control-pagination
fixes named in `specs/pipewire-x716b/README.md` (run
`specs/pipewire-x716b/test-control-pagination.py` against its source), and the
WirePlumber rules in `rootfs/overlay-common/usr/share/wireplumber/`.

## Kernel patches (`kernel/patches/`)

Applied to the pinned mainline kernel by `scripts/build-mainline-kernel.sh`
(`apply_unless <marker> <file> <patch>`: skipped if the marker is already
present, so re-running against a patched tree is a no-op). Order matters where
noted. Distro-independent: every distro boots the same kernel build.

| Patch | Area and why | Upstream outlook |
|---|---|---|
| `unpark-pcie0-pipe-mux` | Samsung's SM8550 boot chain parks the PCIe0 PIPE clock mux on the XO reference; mainline never switches it, so the LTSSM never detects the Wi-Fi/BT endpoint. | Boot-chain quirk of this vendor; unlikely. |
| `qca6390-pwrseq-cold-reset-aop` | Program the AOP WLAN PDC votes over QMP before first power-up (as downstream `cnss2` does), for the board's QCA6490. | Board/firmware specific. |
| `qca6490-xo-clk-gpio` | Wire the XO-clock-enable GPIO into the QCA6390/6490 pwrseq tables and order the AOP vote first, as downstream does. | Same. |
| `configure-nxp-ptn3222-from-dt` | The PTN3222 eUSB2 repeater needs four downstream register overrides; the generic driver ignores the DT property. | Would need a DT binding; possible later. |
| `ignore-console-null` | Samsung's ABL appends `console=null`; opt-in `ignore_console_null` keeps the framebuffer console. | No. |
| `match-samsung-sm8550-eusb2-phy-init` | Match downstream eUSB2 PHY POR delay and CPBIAS so a USB host can read the descriptor. | Possible if generalised; not attempted. |
| `msm-dp-allow-unresolved-usbc-bridge` (1/3) | DP goes through a `usb-c-connector`, not a DRM bridge; don't defer the DP component (it blocks the shared MSM DRM master and the DSI panel). | Board wiring; unlikely. |
| `msm-dp-associate-bridge-of-node` (2/3) | Keep the DP controller's fwnode on the terminal bridge so out-of-band Type-C HPD finds it. | Same. |
| `msm-dp-defer-oob-hpd-until-resume` (3/3) | Implements `qcom,defer-hpd-until-first-resume` (workaround for a cold-boot ordering reset with the ANA38407 panel). | No. |
| `set-mi2s-codec-dai-format` | AudioReach programs LPASS MI2S but never the codec's bit-clock/format; CS35L45 amps stayed silent. | Partly generic; possible, not attempted. |
| `tcpm-adopt-retained-source-ufp-role` (1/2) | Opt-in TCPC quirk: adopt DFP when a still-powered charge-through dock retains Source/UFP across a host reboot. | Hardware quirk; unlikely. |
| `tcpm-use-retained-sink-data-role` (2/2) | Matching Sink/DFP half of the above. | Same. |
| `ath11k-defer-wmm-params-until-vdev-started` | Defer the legacy WMM-params command until the vdev starts; add `ath11k.skip_legacy_wmm_params` (auto: skip on `WLAN.HSP.2.0`), whose firmware has a NULL dereference in that handler. See `docs/wifi-samsung-calibration.md`. | Samsung-firmware workaround; no. |
| `ath11k-samsung-skip-mu-edca` | Same firmware also faults on MU-EDCA. | No. |
| `camss-log-csi2-rx-irq-status` | **Debug aid**: logs the CSI-2 receiver's error status register that mainline reads and clears silently. It prints on every frame IRQ and floods `dmesg` while a camera runs; a candidate for removal now that the cameras work (needs a kernel rebuild and reflash). | No. |

Adopted in bulk from the sibling Wi-Fi tablet's port (`gts9wifi-fedora`); the
patches deliberately **not** taken from it are listed in the comments of
`scripts/build-mainline-kernel.sh`.

### Out-of-tree kernel code (not patches)

Copied into the kernel tree at build time by `scripts/build-mainline-kernel.sh`
(Kconfig/Makefile lines added idempotently): `kernel/drivers/` holds the
HI1337 and DW9808 camera drivers, the ANA38407 panel, FTS1BA90A touch, Wacom
WEZ01 (S Pen), SM5714 charger/fuel gauge/USB-PD, SM5440 direct charger, PS5169
redriver and the sec-log console. `kernel/dts/sm8550-samsung-x716b.dts` is the
board device tree, `kernel/config/` the config base and this board's fragment.
None of these is upstreamable as is: they are board- or vendor-specific
drivers, some derived from Samsung's GPL downstream sources.

## How a distro uses this

| | Kernel + modules | libssc, pd-mapper, hexagonrpcd, iio-sensor-proxy | libcamera + tuning | SPA plugin | v4l2-relayd | Overlay |
|---|---|---|---|---|---|---|
| **Fedora** (`scripts/build-fedora-rootfs.sh`) | shared kernel build | shared builder | shared builder (`--libdir lib64`) | `build-fedora-camera-spa.sh` (from the SRPM) | shared builder | `overlay-common` + `overlay-systemd` |
| **Debian** (`scripts/build-debian-rootfs.sh`) | shared kernel build | shared builder | **not built yet** (no camera stack) | not built | not built | same |
| **NixOS** (`nixos/`) | shared kernel build | Nix packages reading the same `series` files (hashes pinned by content, so bump both when changing a pin) | **not packaged yet** | not packaged | not packaged | translated to modules |
| Alpine / Ubuntu / Buildroot builders | predate this work and are not maintained (`docs/distro-porting.md`) | - | - | - | - | - |

## Porting checklist

1. Install the distro's build dependencies. Reference lists (the source of
   truth for what the components need): the `dnf_install` blocks in
   `scripts/build-fedora-rootfs.sh` and the `apt-get install` after the
   `meson ninja-build build-essential ...` comment in
   `scripts/build-debian-rootfs.sh`. In short: git, GNU patch, meson, ninja, a C
   and C++ compiler, pkg-config, glib/gudev/systemd/polkit development files,
   libqmi/qrtr/protobuf-c (libssc, hexagonrpcd); gnutls, libyaml, libdrm, libevent,
   boost, elfutils and python3 yaml/jinja2/ply (libcamera); autoconf, automake,
   libtool and the GStreamer development files (v4l2-relayd).
2. Copy `scripts/build-downstream-userland.sh`, `scripts/lib/` and `specs/` into the
   target (they are location independent) and run, inside it as root:
   `build-downstream-userland.sh --prefix /usr [--libdir lib64] all`
   (or a subset; `iio-sensor-proxy` needs `libssc` first).
3. Apply the overlay per `docs/distro-porting.md` (device rules, units,
   ALSA UCM, WirePlumber rules), stage the firmware, install the kernel modules.
4. Build the PipeWire libcamera SPA plugin for the distro's PipeWire (see above).
5. Run `scripts/test-downstream-patches.sh` in CI so a moved pin or a patch that
   stops applying is caught before an image build.

## Known gaps

- Debian and NixOS have no camera stack yet (libcamera, SPA plugin, relayd).
- `sources.lock` pins and the Nix `fetchzip` hashes are maintained separately.
- Patches 0005 and 0006 (libcamera) and the two iio-sensor-proxy patches are the
  ones with a realistic chance of upstreaming; none has been submitted.
- The `camss-log-csi2-rx-irq-status` debug patch is still in the kernel build.
