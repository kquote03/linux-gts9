# Camera controls: focus, exposure, colour, and the `gts9-camera` tool

Everything an application does not decide for itself on the Tab S9's cameras
(autofocus behaviour, exposure, colour) can be changed from the shell with
`gts9-camera`, installed in the image at `/usr/bin/gts9-camera`. It changes the
controls of the camera stream that is running right now, so it works on top of
GNOME Camera, Firefox or anything else that uses the PipeWire camera.

- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [What each control does](#what-each-control-does)
- [Not supported](#not-supported)
- [Making settings stick](#making-settings-stick)
- [How it works](#how-it-works)
- [Setting controls by hand, and adding new ones](#setting-controls-by-hand-and-adding-new-ones)
- [Troubleshooting](#troubleshooting)
- [What has been tested](#what-has-been-tested)

## Quick start

Open a camera application (or any stream), then in a terminal on the tablet:

```sh
gts9-camera list                       # cameras, PipeWire state, whether there is a lens
gts9-camera controls rear              # every control the rear camera offers, with ranges
gts9-camera status rear                # live lens position and sensor exposure/gain

gts9-camera focus rear 300             # move the lens (manual focus), 0..1023
gts9-camera focus rear continuous      # back to continuous autofocus
gts9-camera exposure rear 8000 --gain 2   # manual: 8 ms, gain 2x
gts9-camera exposure rear ev 1         # auto exposure, one EV-step brighter
gts9-camera exposure rear auto         # back to automatic exposure
gts9-camera saturation rear 0          # black and white
gts9-camera reset rear                 # everything back to defaults
```

`rear` and `front` name the cameras (`back` is accepted for `rear`). The two
cameras share one image path, so only one can stream at a time.

A setting lasts only until the application stops and restarts the camera. To
keep settings across restarts and camera switches, enable the small helper
service once:

```sh
systemctl --user enable --now gts9-camera-settings
```

## Command reference

| Command | Effect |
|---|---|
| `list [--json]` | Cameras, their PipeWire node and state, and whether they have a lens. |
| `status [cam] [--json]` | Live lens position, the sensor's real exposure (lines) and gain code, and the settings last made with this tool. |
| `controls <cam>` | Every control the camera offers with range, default and the value last set. |
| `focus <cam> continuous` | Continuous autofocus (the default): scans, locks, and scans again when the scene changes. |
| `focus <cam> auto` | Focus once now, then hold the lens. |
| `focus <cam> trigger` | Start a focus scan (meaningful in `auto` mode). |
| `focus <cam> manual` | Stop autofocus and leave the lens where it is. |
| `focus <cam> <0-1023>` | Manual focus: stop autofocus and move the lens to that position. |
| `exposure <cam> auto` | Automatic exposure and gain (the default). |
| `exposure <cam> <µs> [--gain G]` | Manual exposure time in microseconds (turns auto exposure off), optionally with a gain. |
| `exposure <cam> ev <-2..2>` | Exposure compensation while auto exposure is on. |
| `gain <cam> <1-16>` | Manual analogue gain (turns auto exposure off). |
| `wb <cam> auto\|off` | Automatic white balance on/off. Off holds the current colour gains. |
| `contrast <cam> <0-2>` | Contrast, 1 is normal. |
| `saturation <cam> <0-2>` | Saturation, 1 is normal. |
| `gamma <cam> <0.1-10>` | Gamma, 2.2 is normal. |
| `set <cam> <control> <value>` | Any control by its libcamera name or a friendly name (see `controls`). |
| `reset <cam>` | Restore the defaults (autofocus continuous, auto exposure, EV 0, auto white balance, contrast/saturation 1, gamma 2.2). |
| `zoom ...` | Not supported; explains why. |
| `daemon [--interval s]` | Re-apply remembered settings whenever a stream starts (run by the user service). |

Values outside a control's range are rejected before anything is sent. The
front camera has no lens, so focus commands report that. Exit status is 0 on
success and 1 on any error, with the message on standard error.

## What each control does

**Focus** (rear camera only, DW9808 voice-coil lens, positions 0-1023).
Autofocus is our own contrast-detection algorithm inside libcamera's software
image processing (patches 0002 and 0007 in `specs/libcamera-x716b/`). It works
from image statistics collected on one frame in four, which is about 7 samples
a second at 30 fps.
- It scans 7 positions across the range (128 to 896), then 5 positions in steps
  of 48 around the best one, and locks on the sharpest. A scan takes about 3 s
  and the picture is briefly blurred while it runs.
- While locked it compares each sample with a reference taken just after the
  lock. If the brightness histogram changes a lot (distance above 0.25) or the
  focus score leaves 0.6x-1.6x of its reference for two samples in a row, it
  waits for the scene to hold still and scans again. It also rescans if the
  score falls to 70% for five samples, and about once a minute regardless.
- This is far slower and less precise than the phase-detection autofocus a
  phone uses. It focuses, but expect visible hunting and a few seconds of delay.
- Manual focus only changes the lens position. Which numbers suit near or far
  subjects has not been characterised on this lens; try a few positions with a
  real subject (the SM-X710 port measured a plateau around 307-409 for a close,
  textured subject, not verified here).

**Exposure** (patch 0008). The sensor is driven by an automatic exposure loop
that steers the average brightness to a target.
- `ev` shifts that target by `2^(EV/2)` (so gentler than a true EV, which is a
  full stop, and about half a stop of light per step), within what the five-bin brightness histogram can express, so the
  effect flattens near -2 and +2.
- A manual exposure time is converted to sensor lines at 14.3 µs per line and
  clamped to the sensor's 4 to 3260 lines, that is about 57 µs to 46.7 ms.
  Longer than that asks for the maximum.
- Gain is 1 to 16x, applied as code `(gain - 1) * 16` (code 0 to 240).
- Setting a manual time or gain turns auto exposure off; `exposure auto`
  turns it back on. While auto exposure is on, a manual time or gain is
  remembered but not used.
- `status` shows what the sensor is really using, which is the way to check a
  setting took effect.

**White balance.** `wb off` stops the automatic adjustment (the colour gains are
expected to stay where they were; not tested); `wb auto` resumes it. There is no manual colour
temperature or gain control (see below).

**Colour.** `contrast`, `saturation` and `gamma` act in the software image
pipeline (a colour matrix, a contrast curve and a gamma curve).

## Not supported

- **Digital zoom.** libcamera's software image pipeline has no `ScalerCrop`
  control: the picture is the whole sensor area, scaled or letterboxed to the
  size the application asked for. Supporting zoom would need a crop window plus
  a scaler inside the software debayer (`DebayerCpu`) and the `ScalerCrop`
  control wired through the simple pipeline handler and the IPA. That is real
  work, not a setting. Zoom in the application instead.
- **Manual white-balance gains and colour matrix.** The IPA has `ColourGains`
  and `ColourCorrectionMatrix` controls, but the PipeWire libcamera plugin skips
  array-valued controls, so they are not visible outside libcamera.
- **Manual focus distance in dioptres** (`LensPosition`). The IPA does not expose
  it; use `focus <cam> <0-1023>`, which writes the lens directly.
- **Resolution, frame rate, rotation.** These are chosen by the application.
- **The front camera's focus.** It is fixed focus.

## Making settings stick

libcamera's software IPA resets its controls every time a stream is configured,
which happens whenever an application stops and starts the camera or switches
between the cameras. A one-off command therefore lasts only for the current
stream. `gts9-camera daemon` (run by the user service
`gts9-camera-settings.service`) watches PipeWire and, a second or so after a
camera stream starts, re-sends the settings this tool last made for that camera,
including the manual lens position. There is a short moment of default
settings after each start.

The service is installed but **not enabled** by default because it polls
PipeWire every two seconds:

```sh
systemctl --user enable --now gts9-camera-settings     # keep settings
systemctl --user disable --now gts9-camera-settings    # stop
```

Settings are remembered in `~/.local/state/gts9-camera/state.json` (only what this
tool set; `reset` clears it). They are not read back from the camera: PipeWire
does not publish current values, so `controls` shows "last set", not the live
value. The live values it can show are the lens position and the sensor's
exposure and gain in `status`.

## How it works

```
gts9-camera ──pw-cli set-param Props──▶ PipeWire camera node (libcamera SPA plugin)
                                               │  libcamera Request controls
                                               ▼
                                     libcamera "simple" pipeline
                                               │  ControlList over IPC
                                               ▼
                       software IPA: AGC (exposure), AWB, Adjust (colour), AF ──▶ sensor + lens
gts9-camera ──v4l2-ctl focus_absolute──▶ lens sub-device (manual focus position)
```

- Which controls exist is decided by the IPA, which registers them in its
  `ctrlMap`; the PipeWire plugin lists them as node properties (`PropInfo`), and
  `gts9-camera` reads that list at run time, so a control added to the IPA
  appears in `gts9-camera controls` with its range without changing the tool.
- Autofocus mode and trigger go through PipeWire; the manual lens position is
  written straight to the lens sub-device (`/dev/v4l-subdevN`, entity
  `dw9808-vcm`), the same node autofocus uses. The tool sets manual mode first so
  the autofocus does not fight the write.
- The libcamera side of this is `specs/libcamera-x716b/patches/0002`
  (autofocus), `0007` (scene-change re-trigger) and `0008` (exposure controls);
  see `docs/downstream-patches.md`.

## Setting controls by hand, and adding new ones

`gts9-camera` is a thin wrapper over `pw-cli`; this is what it runs, useful for
scripts or for controls the tool does not know:

```sh
pw-dump <node-id> | less          # PropInfo lists every control: id, description, range
pw-cli set-param <node-id> Props '{ contrast = 1.5 }'       # standard names: contrast,
pw-cli set-param <node-id> Props '{ saturation = 0.0 }'     #   saturation, exposure (µs), gain
pw-cli set-param <node-id> Props '{ 16777217 = false }'     # anything else: 16777216 + the
                                                            #   libcamera control id (AeEnable = 1)
```

Rules that cost time to find out:
- Custom controls are keyed by the **number** `16777216 + <libcamera control id>`
  (`PropInfo` prints it as hex `id-01000001`, which `pw-cli` does not accept as a
  key). Standard ones use their names.
- The value type must match: booleans `true/false`, integers plain, floats
  **with a decimal point** (`-2.0`, not `-2`). A mismatch is rejected inside
  WirePlumber (`set_param ... Invalid argument` in `journalctl --user -u
  wireplumber`), not reported by `pw-cli`.
- The `params = [ "name" value ]` form does not work with this plugin.

To add a control: register it in an IPA algorithm's `init()`
(`context.ctrlMap[&controls::X] = ControlInfo(min, max, default)`), read it in
`queueRequest()`, add the patch to `specs/libcamera-x716b/` and its `series`, and
rebuild libcamera (`docs/downstream-patches.md`). It then shows up in
`gts9-camera controls` automatically.

To watch the autofocus decide, run WirePlumber with debug logging for the IPA and
read the journal (lines starting `AF locked:` show the histogram distance and
focus score that drive the re-trigger; the thresholds `kSceneChange`, `kSettled`
and `kMaxWait` are at the top of `afSceneChanged()` in patch 0007):

```sh
systemctl --user set-environment LIBCAMERA_LOG_LEVELS=IPASoft:DEBUG
systemctl --user restart wireplumber
journalctl --user -u wireplumber -f | grep -E 'AF |exposureMSV'
```

## Troubleshooting

| Message or symptom | Cause and fix |
|---|---|
| `the rear camera is not available in PipeWire` | WirePlumber is not running or the libcamera plugin is missing: `systemctl --user status wireplumber`; `ls /usr/lib64/spa-0.2/libcamera/`. |
| The command succeeds but nothing changes | Wrong value type, or the stream restarted (settings reset each stream; see above). Check `journalctl --user -u wireplumber` for `Invalid argument`, and use `status` to see the real exposure/lens. |
| The front camera will not start while the rear is open | They share one image path; close the other application (a background Snapshot holds the rear camera). |
| Focus jumps back after `focus rear 300` | Autofocus was still active when the lens moved, or the stream restarted; enable the settings service. |
| Manual exposure looks unchanged | Auto exposure is on; `exposure rear <µs>` turns it off, but a later `exposure rear auto` or a stream restart turns it back on. Confirm with `status`. |
| A very bright or dark scene barely reacts to `ev` | The effect saturates: the exposure target is limited to the histogram's range. |

## What has been tested

On the SM-X716B, with the libcamera and IPA patches 0001-0008 and the PipeWire
libcamera plugin:

- `list`, `controls`, `status` (lens and sensor readings), argument and range
  errors, and `zoom` (the explanation) behave as described.
- Manual lens positions are written and read back; autofocus mode changes work.
- Saturation 0 gives an exactly greyscale picture; contrast and saturation change
  the picture live.
- Exposure compensation moves brightness monotonically (EV -2, 0, +2 gave mean
  luminance 166, 185, 199 in one scene); manual exposure time and gain move
  brightness monotonically and set the sensor registers as documented above
  (exposure 69/349/698/2094/3260 lines for 1/5/10/30/100 ms, gain code
  0/16/48/112/240 for 1/2/4/8/16x).
- The settings daemon re-applied a setting after the stream was stopped and
  restarted; without it the setting was lost.

Not tested: the front camera's controls beyond `list`/`controls`, `wb off` on a
scene with changing light, long-running use of the daemon, and how autofocus
tuning behaves on a wide range of subjects (thresholds are first guesses; the
scene-change re-trigger was tried by hand with a hand moved in front of the
lens and worked, but not measured).
