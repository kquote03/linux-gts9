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
2. **Quirk** — module parameter, **off by default**:

   ```
   ath11k.skip_legacy_wmm_params=1
   ```

   When set, the legacy `WMI_VDEV_SET_WMM_PARAMS` send is skipped
   entirely (all three call sites). Host-configured WMM/EDCA tuning is
   lost — mac80211 and firmware fall back to their own defaults — but
   the firmware NULL-deref is avoided. Only relevant when running the
   `HSP.2.0` firmware; harmless (but pointless) otherwise. The firmware
   is PIL-signed, so patching the firmware itself is not an option.

The deferral half is a legitimate upstream-shaped fix. The quirk half
is a workaround for a bug that lives in a closed, signed firmware blob.

## Result (measured on real hardware)

Same tablet, community firmware vs. Samsung matched triple + quirk, back
to back over the same real network (noisy home/campus environment,
different bands/APs between samples — treat magnitudes as indicative,
not lab-grade):

| | community `HSP.1.1` | Samsung `HSP.2.0` + quirk |
|---|---|---|
| BDF parse / boot | works | works |
| Crashes over a sustained transfer | n/a (stable) | **zero `MHI_CB_EE_RDDM`** |
| Per-chain RSSI | `-57 [-93, -57]` (one chain at noise floor) | `-68 [-68]` (single healthy chain, no dead chain) |
| Spatial streams | NSS 1 effective | **NSS 2**, VHT-MCS 4 rx / MCS 9 tx |
| Download throughput | ~1.0 MB/s (~8 Mbit/s) | **~5 MB/s (~40 Mbit/s)** |

Samsung's calibration delivered ~5× the throughput at a *weaker* signal
on a *harder* band, and the "one dead chain" signature that defined the
whole investigation is gone. The core hypothesis — generic calibration
does not fit this board, its own factory calibration does — is
confirmed.

## How to reproduce

### The kernel fix (already in-tree, distro-agnostic)

`scripts/build-mainline-kernel.sh` applies the patch idempotently
(marker: `Flush WMM params deferred by ath11k_mac_op_conf_tx`). A fresh
`scripts/fetch-mainline.sh` + `scripts/build-mainline-kernel.sh` picks
it up automatically. `CONFIG_ATH11K_DEBUG=y`
(`kernel/config/config-x716.fragment`) is **not required by the fix** —
it was added for the investigation (verbose QMI/WMI/boot tracing via
`debug_mask`) and is kept because it is cheap and useful for any future
WiFi work.

### Using Samsung's calibration (manual — not yet a default)

This is deliberately **not** wired into the image build. Samsung's
`amss20.bin` / `m3.bin` / `bdwlan.elf` are extracted from this specific
unit; bundling them into a redistributable rootfs is a licensing
decision left open. To use them:

1. Stage the three files as
   `ath11k/WCN6855/hw2.1/{amss,m3,board-2}.bin` where the kernel
   firmware loader looks — either
   `/lib/firmware/ath11k/WCN6855/hw2.1/` (persistent, any distro), or a
   tmpfs dir pointed at by `/sys/module/firmware_class/parameters/path`
   (non-persistent, self-heals on reboot — see the test harness).
   `board-2.bin` is `bdwlan.elf` re-wrapped into the `board-2.bin` TLV
   container as this device's exact-match entry — see
   `scripts/` note below.
2. Set the quirk before the driver probes:
   - kernel cmdline: `ath11k.skip_legacy_wmm_params=1`, or
   - `echo 1 > /sys/module/ath11k/parameters/skip_legacy_wmm_params`
     then re-probe (`unbind`/`bind` the PCI device).
3. `unbind`/`bind` `0000:01:00.0` on
   `/sys/bus/pci/drivers/ath11k_pci/`, or reboot.

Both staging methods and both quirk-setting methods are
distro-agnostic (no systemd, no NetworkManager dependency). For a
persistent deployment the firmware files belong in
`rootfs/overlay-common/lib/firmware/ath11k/WCN6855/hw2.1/` and the
cmdline arg in the boot bundle
(`scripts/build-android-v4-bundle.sh`'s `cmdline`).

### The crash-safe test harness

`board-2.bin` builder and the live test scripts used for this
investigation are scratch (kept under a working dir, not committed).
The key idea for anyone repeating this: stage test firmware in tmpfs and
point `/sys/module/firmware_class/parameters/path` at it — it is
searched before `/lib/firmware`, is **not persistent**, and
`/lib/firmware` is never touched, so any reboot (watchdog included)
comes back clean. No TWRP rescue is ever needed. A firmware RDDM
coredump, when one is produced, lands in `/sys/class/devcoredump/` and
must be copied out within ~5 minutes (reading it frees it).

## Open follow-ups

- Auto-gate the quirk on the firmware `build_id` (`fw_version` /
  `HSP.2.0` detection at runtime) instead of a manual toggle.
- Decide on redistribution of the Samsung firmware blobs; if yes, wire
  the overlay + cmdline in and make it the default.
- A controlled same-position / same-band / same-AP A/B to pin the exact
  throughput delta.
- `cause=0x7003` has no decodable meaning in anything available locally;
  naming *what* fails to populate `wal_pdev->[0x37c]` would need the
  QShrink message DB for this exact firmware build. Not required — the
  faulting instruction, address and NULL base are established directly.
