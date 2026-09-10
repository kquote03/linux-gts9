# Charging follow-up: closed-loop hardening (round 2)

This is the follow-up to `docs/charging.md`. That document describes the
45 W direct-charge + charge-through-suspend design and landed as
`d049a60` (merged `c5c5fd3`). This round is five bug fixes to the
`sm5440_direct.c` closed loop found during the first real-hardware
bring-up, plus what was and was not verified on hardware.

**Status: landed, needs a little further testing.** The fixes are correct
by inspection and the driver was rebuilt, flashed and confirmed to load,
bind, arm the suspend keepalive and *not* regress on a non-PPS charger.
The PPS closed loop itself (Stages 0–4 in `docs/charging.md`) has **not**
been re-run end to end against a PPS adapter since these fixes — see
"What still needs testing" below.

## What changed

All five are in `kernel/drivers/sm5440_direct.c`. No DT, config or
`sm5714_battery.c` change in this round.

### 1. `IBUSCNTL` was only reprogrammed on a step-*index* change

`sm5440_program_ibus()` used to be called only inside the
`if (step != sm->step)` block in `sm5440_work()`. In auto mode the pack
voltage can sit below the first step boundary (4130 mV) for a long time,
and a runtime `target_ibus_ma=` write never moves the index at all, so
the hardware input-current limit stayed pinned at whatever
`sm5440_start()` wrote — the closed loop could aim as high as it liked
and the current was capped in silicon.

Fix: `sm5440_program_ibus()` now self-tracks the last value it wrote
(`sm->prog_ibus_ma`) and is a no-op when nothing changed, so it is called
**every tick** unconditionally. `sm->prog_ibus_ma` is reset to 0 (forcing
the next call to write) in `sm5440_restore_switching()` and in
`sm5440_start()` right before its own `program_ibus` call, because
`sm5440_hw_init()` writes `IBUSCNTL` directly and leaves the tracked
value stale.

Live-verified on hardware via unbind/rebind on the first bring-up:
input current went 1.5 A → 2.8 A immediately once the per-tick write
landed, die 52 °C.

### 2. Request current was not clamped to the source's APDO ceiling

`sm5440_request_ma()` returned `max(pps_op_curr_ma, 15W-floor)` with no
regard for what the attached APDO actually advertises. Over-asking a
source its APDO cannot meet was seen to renegotiate the whole contract
down to 5 V DCP.

Fix: `sm5440_request_ma()` now also reads `POWER_SUPPLY_PROP_CURRENT_MAX`
from the TCPM psy (which exposes the active APDO's max current) and
clamps the ask to it, never below the 15 W floor. Signature gained a
`struct sm5440_direct *` for the psy handle; both call sites updated.

Caveat: `CURRENT_MAX` reflects the APDO ceiling only while a PPS contract
is up; before that it reads the *fixed* contract current, so the very
first `sm5440_start()` request can be under-clamped for a tick or two
before the loop pulls it back up. Harmless (starts low, ramps up) but
noted here.

### 3. Source-foldback detection

Even legal (within-APDO) asks can collapse if the *cable* or adapter
hits its real limit — a non-e-marked cable makes a 65 W brick withdraw
its 5 A rating once sustained bus current passes ~3 A, and the loop,
seeing the current still short of the step aim, would keep climbing the
Request straight into an `-EPROTO` contract collapse.

Fix: the loop remembers last tick's measured VBUS (`sm->last_vbus_mv`).
If VBUS drops more than `SM5440_VBUS_SAG_MV` (300 mV) tick-over-tick
*while the current is not above the aim* (i.e. it is not our own
down-regulation), the loop treats it as foldback: it stops climbing and
eases the Request down toward the level the bus is actually holding,
clamped to `[floor_mv, ceil_mv]`. It then settles at whatever the link
can sustain instead of ending in a 5 V DCP fallback. Logged as
`source foldback: vbus X -> Y mV, easing request to Z mV`.

### 4. One retry before tearing the PPS contract down

A lone `-EPROTO` from `sm5440_refresh_pps()` used to go straight to
`sm5440_restore_switching()` (fall back to the switching charger at 5 V
DCP). A single transient — the source trimming its APDO under load and
the in-flight Request colliding with the renegotiation — should not cost
the whole direct-charge session.

Fix: on a refresh failure the loop now waits 50 ms, re-reads the APDO
current ceiling via `sm5440_request_ma()` (so a genuine APDO trim is
picked up), and retries once. Only if the retry also fails does it hand
back. A clean fall to DCP is still the right *end* state — this just
stops it happening on one blip.

### 5. Anti-windup tightened, `SM5440_SAT_TICKS` 12 → 8

The ceiling anti-windup (ease the Request down after N ticks pegged at
`ceil_mv` with the current still short) was 12 ticks (~12–18 s). On the
first bring-up the contract collapsed at ~10 s of saturation, before the
anti-windup could act. 8 ticks gives it a chance while still being slow
enough not to fight a legitimately slow ramp.

## Reproducibility

### Build

```
nix develop --command bash -c 'BUILD_JOBS=$(nproc) bash scripts/build-mainline-kernel.sh'
nix develop --command bash -c 'BRINGUP_RAMDISK="$(pwd)/out/real-root-initramfs.cpio.gz" bash scripts/build-android-v4-bundle.sh'
```

The **DTB** is the reproducible artifact and the load-bearing check that
this round changed no device tree:

| artifact | sha256 | notes |
|---|---|---|
| `out/kernel/arch/arm64/boot/dts/qcom/sm8550-samsung-x716b.dtb` | `c1a661a7d71cc4d3b46d9c113564c5aca61fc2e32f953530a268d5a91abbe1fc` | **stable** — identical to the `d049a60` build; no DT change this round |

The kernel `Image` and the `boot`/`init_boot`/`vendor_boot`/`dtbo` bundle
images are **not** bit-for-bit reproducible: the build scripts do not pin
`KBUILD_BUILD_TIMESTAMP` / `SOURCE_DATE_EPOCH`, so the timestamp embedded
in `linux_banner` differs every build (two clean builds of this exact
commit produced `Image` `a2494b92…` and `d2a5eb7f…`). What is reproducible
is the **source** at this commit and the **DTB**. If bit-identical images
are ever needed, export `KBUILD_BUILD_TIMESTAMP` (and
`KBUILD_BUILD_USER`/`HOST`) before the build.

The build actually flashed to the device for the round-2 hardware check
below was:

| artifact | sha256 |
|---|---|
| `out/kernel/arch/arm64/boot/Image` | `a2494b929d8b79162dc54b166c3e347636d654b42b3ba8fac4b402f2dc173fd3` |
| `out/android/boot.img` | `83cee3834b2a91b6d0d67fb62e9b254a42706140a6a1366b749a35100fdddd5b` |
| `out/android/init_boot.img` | `51b78cb3a1ab3fb01540c09d3bd1f353fdd2d9960a55aaf00072e777646d6a92` |
| `out/android/vendor_boot.img` | `cd4f484df694da44c6bd31ffcbbdc2579ab180a4fac32e43be0ee887cb9d4383` |
| `out/android/dtbo.img` | `92c92c934bfdd66cef5885474476d8e481bb561ae7d25c9f4405b62fa606e58f` |

### Flash (device in TWRP, `adb devices` → `... recovery`)

```
nix develop --command bash -c 'bash scripts/flash-boot-set.sh --i-understand-this-writes-to-the-device \
  boot=out/android/boot.img init_boot=out/android/init_boot.img \
  vendor_boot=out/android/vendor_boot.img dtbo=out/android/dtbo.img'
```

Non-slotted partitions: `boot`→sda21, `init_boot`→sda22,
`vendor_boot`→sda24, `dtbo`→sda30. The script reads every partition back
and verifies. Pre-charging rollback images are kept at
`out/android/backup-pre-charging/`.

### Runtime knobs

`/sys/module/sm5440_direct/parameters/{verbose,pps_op_curr_ma,target_ibus_ma}`
(all 0644). Force a clean restart of the driver without reflashing:

```
echo 0-0063 | sudo tee /sys/bus/i2c/drivers/sm5440-direct/unbind
echo 0-0063 | sudo tee /sys/bus/i2c/drivers/sm5440-direct/bind
```

## What was verified on hardware (this round)

Flashed build `a2494b92…`, booted `7.2.0-dirty`:

- Driver loads, binds `0-0063`, logs
  `SM5440 direct charger device ID 0x21 (suspend keepalive armed)`.
- `rtc0` = `rtc-pm8xxx` present (keepalive prerequisite).
- PM ops clean: `sm5440_suspend` / `sm5440_resume` both return 0 in the
  boot-time autosleep cycles, no *"Transfer while suspended"*.
- **Non-PPS charger regression: clean.** The charger connected for this
  session turned out to advertise **fixed PDOs only** (5/9/12/15/20 V,
  all 3 A — no APDO). `sm5440_eligible()` correctly gated direct charge
  off: driver idle, **zero `-95` / retry spam**, charging continued on
  the fixed 9 V / 1.66 A contract via `sm5714_battery.c`
  (~7.8 W into an 82 % pack).

## What still needs testing

Blocked on: a real **PPS** adapter (the Samsung 45 W EP-T4510 / EP-TA845,
which has a 3.3–11 V / 4.05 A APDO) **and** a pack drained low enough for
a meaningful run (`sm5440_eligible()` stops at ≥ 90 % / ≥ 4.35 V).

1. **Stages 0–2 of `docs/charging.md`** re-run against a PPS adapter with
   the round-2 loop — confirm the per-tick `IBUSCNTL` write ramps input
   current to the step aim, the step table hands off at 4130 / 4250 mV,
   CV hand-off is clean ~4430 mV.
2. **Fix 3 (foldback) actually firing** — reproduce the sag with a
   3 A / non-e-marked cable and confirm the loop eases the Request and
   *settles* (log line present, no DCP fallback) rather than collapsing.
3. **Fix 4 (refresh retry)** — confirm a transient `-EPROTO` is ridden
   through (log shows `PPS refresh failed (…), retrying` then normal
   ticks, session survives).
4. **Full 45 W** — bus ~4.3 A at ~9 V, battery-side ~8.6 A in step 1,
   pack < 42 °C, die < 90 °C, with a 5 A e-marked cable.
5. **Stages 3–4** — suspend keepalive short cycles, then a full
   0 → 100 % suspended charge.

Only after Stage 4: consider widening `SM5440_IBUS_CLAMP_MAX_MA` / the
`SM5440_MAX_HEADROOM_MV` ceiling.
