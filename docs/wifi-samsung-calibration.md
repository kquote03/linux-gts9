# WiFi throughput: using Samsung's own factory calibration data

Samsung Galaxy Tab S9 5G (SM-X716B), Qualcomm QCA6490 / WCN6855, `ath11k`.

This is the resolution of the multi-session WiFi throughput investigation
(`docs/porting-log.md`, "WiFi throughput bring-up session" through
"round 3"). Everything here was verified on the physical tablet.

## The problem

With this project's normal, community-sourced firmware set
(`linux-firmware`'s `ath11k/WCN6855/hw2.1/{amss,board-2,m3,regdb}.bin`),
WiFi associates and works but throughput is stuck around **6–9 Mbit/s**
regardless of signal, and `iw dev wlp1s0 station dump` consistently shows
one RX chain pinned near the noise floor:

```
signal:  -57 [-93, -57] dBm      # chain 0 dead, chain 1 fine
rx bitrate: 57.8 MBit/s MCS 5    # 1x1-effective, poor MCS for -57 dBm
```

Three earlier rounds of software/DT/Kconfig fixes (power-save default,
DTS chip-identity/regulator correctness, a `cold_reset_wlan` regression)
were each real and correct but moved neither throughput nor the chain
imbalance. The remaining suspect was the **board data (BDF /
`board-2.bin`) calibration** itself: the generic community entry that
matches this device's PCI/subsystem ID is not this board's real factory
antenna/gain calibration.

## Root cause, in three layers

### 1. Community calibration doesn't fit this board

This unit's own factory calibration was dumped from its eMMC
(`vendor-firmware-dump/firmware/qca6490/…`). Feeding Samsung's real
`bdwlan.elf` payload to the **community** `amss.bin`
(`WLAN.HSP.1.1-03125-…`) crashes the WLAN firmware during BDF parse
(`MHI_CB_EE_RDDM`), every time, in every representation tried (full
payload, ELF-wrapped vs raw, header-normalised, checksum-corrected,
split at any boundary). Samsung's BDF is authored for a **different
firmware generation** and the `HSP.1.1` parser cannot ingest it.

### 2. Samsung's matched firmware set gets much further — then hits a real firmware bug

Pairing Samsung's own version-matched set — `amss20.bin`
(`WLAN.HSP.2.0.c11-00358-…`) + Samsung's own `m3.bin` + `bdwlan.elf` —
the BDF loads and parses **cleanly**, the chip reaches mission mode,
`ath11k`/mac80211 bring up `wlp1s0`, and a real connection begins.
Then, **~880 ms into operation**, `MHI_CB_EE_RDDM`.

Root-caused from the firmware's own RDDM coredump
(`/sys/class/devcoredump/`, captured via the harness below):

- The dump carries a `Q6-SFR` subsystem-failure string:
  `ExIPC: Exception recieved tid=1a inst=0x17be7d0 cause=7003` — a real
  CPU exception at a fixed firmware PC (not a deliberate assert).
- Disassembling `amss20.bin` around that PC (Hexagon/QuRT; the `EM_ARM`
  ELF header is PIL convention, the code is Hexagon): the faulting
  instruction is `r3 = memub(r3 + ##0x608)`, whose base chains
  `vdev → soc->pdev[mac_id] → wal_pdev → +0x37c`, and in the live
  `Q6-SRAM` image that `wal_pdev->[0x37c]` word is **NULL**.
- The enclosing routine reads `cmd+0x04` (vdev_id), `cmd+0x78`
  (`wmm_param_type`), and steps a per-AC pointer by `0x1c` =
  `sizeof(wmi_wmm_params)` — i.e. it is the handler for
  **`WMI_VDEV_SET_WMM_PARAMS_CMDID`** (0x500D). The killing command was
  recovered from firmware RAM: cmd id `0x500D`, vdev 0, mac80211's
  default STA WMM params.
- The exact 8-byte fault instruction pattern occurs **3× in
  `amss20.bin` (HSP.2.0)** and **0× in the community `amss.bin`
  (HSP.1.1)** — an exhaustive whole-file scan. This is new HSP.2.0 code
  with a missing NULL guard.

### 3. Not a timing bug

`ath11k`'s first instinct was that mac80211 sends `conf_tx()` (hence
`WMI_VDEV_SET_WMM_PARAMS`) at raw interface-up, before the vdev is
started — so the fix tried was to defer that send until
`arvif->is_started`. Live WMI tracing showed the deferred send then goes
out later, with correct values, and crashes at the **identical ~879 ms
delay**. Sending the command at interface-up, at peer-add, or at a
fully-started vdev — all three call sites, same crash. The bug is
**unconditional** in that firmware build's WMM-params handler.

## The fix

`kernel/patches/ath11k-defer-wmm-params-until-vdev-started.patch`
(wired into `scripts/build-mainline-kernel.sh`, applied to
`drivers/net/wireless/ath/ath11k/mac.c`):

1. **Deferral** (kept — it is correct regardless): `conf_tx()` caches
   WMM params into `arvif->wmm_params` but only sends the WMI command
   once `arvif->is_started`; the cached values are flushed once from
   both `ath11k_mac_op_assign_vif_chanctx()` and
   `ath11k_mac_start_vdev_delay()` (the latter is where `is_started`
   actually transitions for `hw_params.vdev_start_delay` chips —
   wcn6855 hw2.1 included). This also fixes a real latent wart: without
   it, `ath11k` sends three all-zero AC entries on the first
   `conf_tx()`.
2. **Quirk** — `ath11k_mac_skip_legacy_wmm_params()`, controlled by the
   `ath11k.skip_legacy_wmm_params` module parameter:

   | value | behaviour |
   |---|---|
   | `-1` (default) | **auto** — skip only when the running firmware's `fw_build_id` contains `WLAN.HSP.2.0` |
   | `0` | always send (pre-fix behaviour) |
   | `1` | always skip |

   When skipping, the legacy `WMI_VDEV_SET_WMM_PARAMS` send is dropped
   at all three call sites; host-configured WMM/EDCA tuning is lost —
   mac80211 and firmware fall back to their own defaults. On the
   community `HSP.1.1` firmware the auto default is a no-op, so the
   patch is inert until Samsung's `HSP.2.0` firmware is actually
   present. The firmware is PIL-signed, so patching the firmware itself
   is not an option.

The deferral half is a legitimate upstream-shaped fix. The quirk half
is a workaround for a bug that lives in a closed, signed firmware blob.

## Result (measured on real hardware)

Same tablet, same real network. The community numbers are from a
back-to-back sample earlier in the session; the Samsung numbers are from
the final **cold boot** with everything permanent (flashed kernel +
initramfs, committed firmware, auto-quirk — no manual steps). Noisy
real-world environment, so treat magnitudes as indicative:

| | community `HSP.1.1` | Samsung `HSP.2.0` (auto-quirk) |
|---|---|---|
| Boot / BDF parse | works | works, no crash |
| `MHI_CB_EE_RDDM` over a sustained transfer | n/a (stable) | **zero** |
| Per-chain RSSI | `-57 [-93, -57]` (one chain at the noise floor, ~36 dB gap) | `-65 [-69, -67]` (**both chains healthy, ~2 dB apart**) |
| Spatial streams | NSS 1 effective (MCS 5) | **NSS 2**, VHT-MCS 5 rx / MCS 9 tx (~173 Mbit/s PHY) |
| Download throughput | ~1.0 MB/s (~8 Mbit/s) | **~10 MB/s (~85 Mbit/s)**, 3/3 samples |

~10× the throughput, and the "one dead chain" signature that defined the
whole investigation is gone — both RX chains are now live and matched.
The core hypothesis — generic calibration does not fit this board, its
own factory calibration does — is confirmed.

### Cold-boot integration note

ath11k's multi-stage firmware load straddles the initramfs →
switch_root boundary: `amss.bin` can be fetched from the initramfs and
`board-2.bin` from the real root. If the two `/lib/firmware` trees hold
different firmware *generations*, that mismatch is itself the RDDM
crash. So `scripts/build-real-root-initramfs.sh` (which already copies
`buildroot/firmware-overlay/lib/firmware` in) must be re-run whenever
`fetch-ath11k-firmware.sh` changes the set — both trees must carry the
same generation.

## How it's wired in (the default, as of 2026-09-10)

Both halves are in-tree and on by default; nothing needs setting by
hand.

### Firmware — committed, no fetch needed

`buildroot/firmware-overlay/lib/firmware/ath11k/WCN6855/hw2.1/` is
committed with the Samsung set already in place, so `build-rootfs` /
`build-real-root-initramfs.sh` pick it up with no extra step and no
per-distro change. **A from-scratch build never has to run
`fetch-ath11k-firmware.sh`.**

`scripts/fetch-ath11k-firmware.sh` only *regenerates* the overlay.
`WIFI_CAL=samsung` (default) is **fully offline and byte-deterministic**
— all inputs are committed:

- `vendor-firmware-dump/firmware/qca6490/{amss20.bin,bdwlan.elf,m3.bin}`
- `buildroot/firmware-src/board-2.bin.wcn6855-community` — the pristine
  upstream `linux-firmware` `board-2.bin`, kept here so the wrapper base
  doesn't have to be downloaded.

`scripts/build-samsung-board2.py` replaces only this device's own
exact-match board entry's DATA in that community container with
`bdwlan.elf`; every other entry stays byte-identical. Running it (or the
fetch script) again produces the committed `board-2.bin` bit-for-bit
(sha256 `9e08bbe0…`).

`WIFI_CAL=community` restores the upstream-only set — this one *does*
hit the network (wget from `linux-firmware`), for an A/B or an unpatched
kernel.

Redistribution: `vendor-firmware-dump/` and
`buildroot/firmware-overlay/` are already committed to this repo per an
earlier explicit decision (`.gitignore` header, 2026-09-07) — the
Samsung/Qualcomm binaries are not this project's to relicense, and that
caveat is documented in `docs/hardware-facts.md`.

### Kernel — `kernel/patches/ath11k-defer-wmm-params-until-vdev-started.patch`

Applied idempotently by `scripts/build-mainline-kernel.sh` (marker
`ath11k_mac_skip_legacy_wmm_params`). The quirk defaults to `-1` (auto),
so on the staged `HSP.2.0` firmware it activates itself and on any
`HSP.1.1` firmware it is inert. `CONFIG_ATH11K_DEBUG=y`
(`kernel/config/config-x716.fragment`) is **not required** — kept
because it is cheap (runtime-gated by `debug_mask=0`) and was essential
for root-causing this.

### Overriding at runtime (any distro, no systemd/NM dependency)

- Force the old firmware: build with `WIFI_CAL=community`.
- Force quirk state: `ath11k.skip_legacy_wmm_params={0,1}` on the kernel
  cmdline, or `echo N > /sys/module/ath11k/parameters/skip_legacy_wmm_params`
  then re-probe (`echo 0000:01:00.0 > /sys/bus/pci/drivers/ath11k_pci/{unbind,bind}`).

### The crash-safe test harness (for anyone re-testing firmware)

Stage candidate firmware in a tmpfs dir and point
`/sys/module/firmware_class/parameters/path` at it — it is searched
before `/lib/firmware`, is **not persistent**, and `/lib/firmware` is
never touched, so any reboot (watchdog included) comes back clean. No
TWRP rescue is ever needed. A firmware RDDM coredump, when produced,
lands in `/sys/class/devcoredump/` and must be copied out within
~5 minutes (reading it frees it).

## Open follow-ups

- A controlled same-position / same-band / same-AP A/B to pin the exact
  throughput delta (tonight's samples were real but across different
  bands/APs/positions).
- `cause=0x7003` has no decodable meaning in anything available locally;
  naming *what* fails to populate `wal_pdev->[0x37c]` would need the
  QShrink message DB for this exact firmware build. Not required — the
  faulting instruction, address and NULL base are established directly.
- If this ever goes upstream: the deferral half is submittable as-is;
  the quirk half would want a maintainer's call on whether a
  build-id-string match is acceptable or it should be a documented
  known-bad firmware instead.
