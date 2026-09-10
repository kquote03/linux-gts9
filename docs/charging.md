# Charging: 45 W direct charge + charging through suspend

Samsung Galaxy Tab S9 5G (SM-X716B), Silicon Mitus **SM5714** (USB-C/PD PHY
+ MUIC + switching charger + fuel gauge) and **SM5440** (2:1 PPS
direct-charge pump). Both drivers are from-scratch on mainline frameworks
(`TYPEC_TCPM`, `power_supply`); there is no mainline support for either
chip. Pack: **8400 mAh rated** (base Tab S9, `EB-BX716ABY`).

This is the resolution of "charging works but is far too slow, and the
tablet does not charge while asleep" (`docs/porting-log.md`, USB
host/charging entry: *"documented as observed working ... not as a fully
closed-out ✅ ... warrants more extended real-world testing"*).

## The two problems

1. **Too slow on every charger.**
   - On a PPS adapter the SM5440 pump negotiated a hard **~15 W**: a
     `min(target_ma, 2200)` clamp in `sm5440_start()`, 700 mV of headroom
     that the board's 0.32 Ω `r_ttl` swallowed at any real current, and no
     closed loop — so it sagged into REVBLK and usually collapsed the PPS
     contract to a 5 V DCP fallback.
   - On a non-PPS (DCP) brick, `sm5714_battery.c` capped fast-charge at
     2100 mA.
   - Stock Android pulls up to **45 W** here, on a 3-step direct-charge
     current profile.
2. **Does not charge while asleep.** `sm5440_direct.c` had no
   `dev_pm_ops`; its 1 s poll `schedule_delayed_work` ran straight into
   system suspend and touched `&i2c_hub_3` (GPI/GSI-DMA) after that bus
   suspended → *"Transfer while suspended"* → the whole PD contract
   dropped to 5 V DCP. TCPM has no PPS keepalive of its own and no
   `dev_pm_ops`, so a PPS/APDO contract also dies within ~10 s of the sink
   going quiet in s2ram.

## Every number here is this model's own

The single most important constraint on this work: **the pack is
8400 mAh, not 9800.** Samsung's stock sec-battery node carries
`battery,battery_full_capacity = 0x2648` (9800) and
`battery,ttf_capacity = 0x251c` (9500), but those are fuel-gauge / CISD
internal constants — they appear **identically on the S9 Ultra (X910)**,
which has a physically larger pack, so they are not the pack rating.

`android_kernel_samsung_gts9` is the **base Tab S9** (X716/X710/X715/…),
**not** the Ultra. Every numeric constant below is taken from this
model's own stock DTS
(`android_kernel_samsung_gts9/.../gts9/gts9_eur_openx_w00_r04.dts`,
verified identical across r00–r04), **never** from
`ubuntu-galaxy-tab-s9ultra/` (whose `sm5440_direct.c` the closed-loop
*algorithm shape* was lifted from — but not one of its numbers; the Ultra
driver's own DTS even repeats the 9800 mistake).

| stock DTS property | value | used as |
|---|---|---|
| `battery,max_charging_charge_power` | 45000 mW | direct-charge ceiling |
| `battery,dc_step_chg_cond_vol` | 4130 / 4250 / 4440 mV | step transition thresholds (`sm5440_step_vpack_mv`) |
| `battery,dc_step_chg_val_iout` | 8660 / 7420 / 5940 mA | battery-side current per step (`sm5440_step_ibat_ma`) |
| — (÷2, the 2:1 pump) | 4330 / 3710 / 2970 mA | pump input current per step (`sm5440_step_ibus_ma`) |
| `battery,chg_float_voltage` | 4440 mV | `SM5440_VFLOAT_MV` (hard CV ceiling) |
| `sec-direct-charger` `charger,dchg_min_current` | 2000 mA | `SM5440_MIN_IBAT_MA` (CV-taper hand-off) |
| `sec-direct-charger` `charger,dchg_min_vbat` | 3400 mV | `SM5440_DCHG_MIN_VBAT_MV` |
| `sm5440,freq` | 850 kHz | `SM5440_FREQUENCY_KHZ` |
| `sm5440,freq_siop` | 450 / 650 kHz | SIOP thermal derate steps |
| `sm5440,r_ttl` | 0.32 Ω | why the headroom is 1100 mV and the loop is closed |
| published pack spec | 8400 mAh | `charge-full-design-microamp-hours` |

8660 mA into an 8.4 Ah pack is ≈ **1.03 C** — Samsung's own step-1
number, not an inflated one.

## The fix

### `kernel/drivers/sm5440_direct.c` — rate

- **Deleted the 15 W cap.** `sm5440_start()` now sets
  `target_mv = sm5440_target_mv(battery_uv)` /
  `target_ma = sm5440_request_ma(target_mv)` and programs the pump's
  hardware input-current limit (`IBUSCNTL`) from the step table. Initial
  headroom 700 → **1100 mV**; VBUS-settle gate widened `−500` → `−700 mV`
  over 40 (was 30) iterations.
- **Closed loop in `sm5440_work()`** (Ultra algorithm shape, X716
  numbers). Each tick: read pack voltage, pick the step, measure pump
  input current, nudge the PPS request ±40 mV toward that step's target
  current, clamp to `[2·Vpack + 1100 mV, min(2·Vpack + 2000 mV,
  10500 mV)]`, re-send the Request every ~2 s, re-program `IBUSCNTL` on a
  step change. Regulating on the *current* reading, not voltage — the
  chip's VBUS ADC disagrees with the adapter by hundreds of mV and the
  gap grows as current falls.
- **Switching frequency** 450 → **850 kHz** (stock), with a SIOP derate
  to 650 then 450 kHz as the die / pack warms, applied only on change.
- **Clean CV hand-off** (not logged as a fault): at `Vpack ≥ 4430 mV`, or
  pump input tapered below `dchg_min_current / 2` for three ticks, stop
  the pump and let `sm5714_battery` finish the CV tail on the switching
  charger. The eligibility check keeps it from restarting until the pack
  falls back below 4.35 V.
- **PPS entry gate.** `sm5440_eligible()` now also requires the TCPM
  power-supply to report `USB_TYPE == PD_PPS` (or `PD_PPS_SPR_AVS`). TCPM
  sets that only from a source APDO, which is the *same* condition that
  makes `tcpm_pps_activate()` return `-EOPNOTSUPP` (−95). Before this the
  driver retried a PPS hand-off against every plain DCP / fixed-PD brick
  every 30 s, forever.
- **INT1–4 latch read-out** on every stop (regs 0x00–0x03; `0x02` bit 1 =
  REVBLK), so a stop at zero current and a stop at a couple of amps are
  distinguishable from the log.

Three independent layers hold the pack at ≤ 4440 mV and never move: the
pump's own `VBATREG` backstop (4400 mV), the `Vbat > 4450` stop check in
`sm5440_work()`, and `sm5714_battery`'s separate CV loop. The step table
maxes at 8660 mA battery-side; the bus-side hardware clamp is 4800 mA.
Pack-temperature stop is **44.0 °C** and die stop **110 °C** — both
deliberately stricter than Samsung's stock 65/70 °C gates, because those
watch a *charger*-side thermistor and `POWER_SUPPLY_PROP_TEMP` here is the
pack thermistor.

### `kernel/drivers/sm5440_direct.c` — charging through suspend

Accepts a non-idiomatic RTC/alarm keepalive rather than the
mainline-normal "drop to fixed-PD on suspend".

- The poll work moved from `schedule_delayed_work` (plain `system_wq`) to
  `queue_delayed_work(system_freezable_wq, …)`. System suspend freezes
  that queue between `.suspend` and thaw, so the poll simply **does not
  run** in the window that used to fault with *"Transfer while
  suspended"*. This alone fixes problem 2 for the fixed-PD case.
- An `ALARM_BOOTTIME` alarm (`sm5440_keepalive_fire`) wakes the system
  every **8 s**. `.suspend` pets the pump watchdog and arms it; the
  alarmtimer core programs the soonest expiry into the RTC as the system
  goes down. On each wake, `sm5440_work()`'s keepalive tail — which runs
  only after thaw, so every bus is back — pets the watchdog, re-reads
  pack + die temp (stricter asleep limits: pack ≥ 44 °C or die ≥ 80 °C
  hands back), and re-sends the PPS Request so the programmable contract
  survives the next sleep window. A named `wakeup_source` is held from
  the alarm callback until that tail completes, so the wake is not
  treated as spurious.
- **Needs a wake-capable RTC.** `sm->keepalive_capable =
  !!alarmtimer_get_rtcdev()` at probe. If there is no `rtc0`, `.suspend`
  falls back to handing the pack to the switching charger for the sleep —
  the mainline-normal behaviour — and picks direct charge back up on
  resume. This is why `CONFIG_RTC_DRV_PM8XXX=y` was added (see below).
- **Failure is self-limiting.** The pump's own `WDT_EN | WDT_30S`
  disables it within 30 s of any missed keepalive; the next real resume
  sees the pump off and restores the switching charger. There is **no**
  second alarm in `sm5714_battery.c`.

### `kernel/dts/sm8550-samsung-x716b.dts`

One line: `charge-full-design-microamp-hours` `8160000` → **`8400000`**
(the X710 figure the node was seeded with → this model's published pack
rating). `voltage-max-design-microvolt` already matched stock at
4440000. This node feeds `sm5714_battery`'s time-to-full estimate, not
the fuel gauge's state-of-charge.

**No other DT change.** `sm5440` `r_ttl` / `freq` stay as driver
`#define`s; `PDO_PPS_APDO` was **not** added to `sink-pdos` — TCPM v7.2
keys PPS purely off the charger's *source* caps, the DT sink list does
not engage it, and Samsung's 15 W `op-sink-microwatt` on the fixed path
is deliberate.

### `kernel/drivers/sm5714_battery.c`

`sm5714_configure_charging()` DCP branch: `fast_ma` 2100 → **2200** (this
pack's stock DCP fast-charge ceiling). The warm-band `SM5714_THERMAL_
REDUCED` clamp still pulls it back to the well-tested 2100. The 9 V /
1660 mA fixed-PD clamp, the `mv > 9000 || ma > 3000` reject in
`sm5714_battery_set_pd_contract()`, and the pack-thermistor STOP 50 °C /
REDUCED 46 °C thresholds are all unchanged.

### `kernel/config/config-x716.fragment`

`CONFIG_RTC_DRV_PM8XXX=y` (mainline defconfig and our vendored base both
leave it `=m`; this port never modprobes). Matches
`pmk8550.dtsi`'s `pmk8550_rtc: rtc@6100` (`qcom,pmk8350-rtc`, ships
enabled, dedicated `alarm` reg bank + alarm IRQ). Without it there is no
`rtc0` and the suspend keepalive silently degrades to the fixed-PD
fallback. Everything else the charging path needs (`TYPEC_TCPM`,
`BATTERY_SM5714`, `CHARGER_SM5440_DIRECT`, `QCOM_GPI_DMA`, `PM_SLEEP`,
`SUSPEND`, `RTC_CLASS`) was already `=y`.

## Bring-up knobs (module params, `/sys/module/sm5440_direct/parameters/`)

| param | default | purpose |
|---|---|---|
| `pps_op_curr_ma` | 4500 | operating current asked for in the PPS contract (min 1000 / max 5000). 45 W / ~9 V bus ≈ 5 A; 4500 leaves margin under a 5 A APDO / e-marked cable. Only raise with a cable rated for it. |
| `target_ibus_ma` | 0 | `0` = follow the step table. Non-zero **pins** the pump input current the loop aims for (min 800 / max 4800) — for staged validation only. |
| `verbose` | 0 | log every regulation tick (`step`, request, aim, vbus/ibus/vbat, pack/die temp). |

## Staged validation (real hardware, `&uart7` console attached throughout)

Do these in order; each has an abort condition. Do not skip ahead.

| stage | setup | pass | abort |
|---|---|---|---|
| **0 — instrument** | `target_ibus_ma=1100 pps_op_curr_ma=3000 verbose=1` | loop trace sane, no REVBLK, INT latches clean | any INT fault / bus error |
| **1 — manual ramp** | pin `target_ibus_ma` 1500 → 2000 → 3000 → 4000 → 4330, ~5 min/step | Vbus stable, pack < 40 °C, die < 80 °C, Ibat tracks ~2× Ibus | pack ≥ 42 °C, die ≥ 90 °C, Vbus sag > 300 mV, REVBLK → step down then stop |
| **2 — auto step table** | `target_ibus_ma=0`, charge to 90 % | steps hand off at 4130 / 4250 mV, clean CV hand-off ~4430 | thermal gate, oscillation between steps |
| **3 — suspend keepalive** | 5 × 8 s then 5 × 30 s s2ram cycles mid-charge | wakes fire, APDO renewed, no "Transfer while suspended", contract stays PPS | contract drops to 5 V, missed wake, bus fault on resume |
| **4 — full suspend charge** | 0 → 100 % entirely suspended | completes, pack < 42 °C, terminates in CV | any thermal or contract failure → fall back to fixed-PD-in-suspend only |

Only after Stage 4 passes: consider widening
`SM5440_IBUS_CLAMP_MAX_MA` / the headroom ceiling.

### What "working" looks like

- **PPS:** on a ≥ 45 W PPS adapter, bus ~4.3 A at ~9 V and battery-side
  ~8.6 A during step 1; time to 90 % roughly matches stock's TTF
  (`ttf_dc45_charge_current` 8890 mA).
- **DCP:** on a non-PPS brick, input settles at 2200 mA / ~11 W (up from
  2100).
- **Suspend:** `echo mem > /sys/power/state` mid-charge; after 60 s of
  s2ram, `dmesg` shows keepalive wakes, no *"Transfer while suspended"*,
  and the PD contract is still a PPS APDO. SoC climbs across a
  multi-hour fully-suspended charge.
- **Regression:** a plain non-PPS charger must be silent now (no −95
  retry spam); unplug/replug, PPS↔DCP swaps, and thermal-throttle
  entry/exit all clean.

## Distro-agnostic

Entirely `kernel/dts/` + `kernel/config/` + `kernel/drivers/`. Nothing
under `rootfs/` was touched or needed — charge policy, TCPM, the RTC
alarm and the PPS loop are all kernel-level.
