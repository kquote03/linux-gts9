# linux-tabs9-port

Porting mainline Linux + Ubuntu to a Samsung Galaxy Tab S9 5G (SM-X716B,
Qualcomm Snapdragon 8 Gen 2 / SM8550 "kalama").

This is hardware bring-up from near-zero: no existing mainline kernel/devicetree
port for this exact board was found anywhere. See `docs/hardware-facts.md` for
ground-truth device facts and `docs/porting-log.md` for a dated session-by-session
engineering diary. The implementation plan this project follows is summarized
below; phases are tracked as they complete in `docs/porting-log.md`.

## Scope

**Goal (MVP):** a mainline kernel that boots to a shell with a real Ubuntu
root filesystem reachable over SSH/USB networking. Console-less debugging via
a persistent log carveout (`sec_log_buf_region`), since there is no UART cable.

**Explicit non-goals for this phase of the project:**

- Cellular/modem — no mainline story exists for Samsung's Shannon modem IPC on
  this SoC; the `modem` partition is left untouched permanently.
- Display, touchscreen, WiFi/BT, camera, audio, sensors, fingerprint, S-Pen,
  keyboard cover — all deferred to future work once the MVP boots.
- Repartitioning internal UFS storage — the MVP root filesystem lives on the
  microSD card instead, to avoid touching internal partitions before the
  kernel is proven stable.

## Inputs (not part of this repo's history — see `.gitignore`)

- `android_kernel_samsung_gts9/` — Samsung's stock downstream kernel/devicetree
  source for this board family. Used as a reference for hardware wiring
  (regulator names, GPIO numbers, reserved-memory addresses), not as code to
  copy — it targets a completely different (downstream, GKI 5.15) kernel ABI.
- `ubuntu-galaxy-tab-s9ultra/` — a working mainline Ubuntu port for the sibling
  SM-X910 "Ultra" tablet (same SoC family, different board). Used as an
  architectural template only — the two boards diverge in panel, touch
  controller, PMIC rail wiring, and modem presence.
- A TWRP nandroid backup of this exact tablet's `boot`/`init_boot`/
  `vendor_boot`/`dtbo`/`modem` partitions, used to derive ground-truth
  partition sizes and boot image formats.

## Safety

Every device-write step in this project requires a fresh verified TWRP backup
and explicit per-step confirmation before it runs — see `docs/boot-strategy.md`.
