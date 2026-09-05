# Boot strategy

How this port gets a custom kernel running on the Samsung Galaxy Tab S9 5G
(SM-X716B), and the safety procedure every device-write step must follow.
See `docs/hardware-facts.md` for the underlying data this document cites.

## The boot chain

Samsung's stock bootloader (ABL) loads, per the by-name partition map:

- **`boot`** — the "kernel." As of Phase 1, this is **uniLoader**, not the
  raw mainline `Image`. uniLoader itself conforms to the ARM64 Linux
  `Image` header format (so ABL sees a normal-looking kernel), but embeds
  the real mainline kernel `Image`, the board DTB, and a ramdisk as
  compiled-in blobs. At runtime it copies those to fixed addresses
  (`TEXT_BASE`/`PAYLOAD_ENTRY`/`RAMDISK_ENTRY` — see `gts9-5g_defconfig`,
  values are an unverified first attempt), patches the DTB it receives from
  ABL to point at its own embedded ramdisk, then jumps to the real kernel.
- **`init_boot`** — the generic ramdisk, GKI 2.0 style. **Open question**:
  whether ABL's `init_boot` ramdisk matters at all once uniLoader is in the
  `boot` slot (uniLoader uses its own embedded ramdisk instead) — assumed
  to be a don't-care based on reading uniLoader's source, not yet confirmed
  against this device's actual ABL behavior. Keep it populated with
  something valid regardless, in case that assumption is wrong.
- **`vendor_boot`** — DTB, cmdline, bootconfig. **Unverified assumption**:
  whether ABL actually reads the DTB from here or from one appended to
  `boot` — inherited from the X910 reference, not confirmed for X716's ABL.
  uniLoader receives whichever one ABL hands it via `x0` at entry (standard
  ARM64 boot protocol) and doesn't change this question either way.
- **`dtbo`** — planned to be replaced with an inert, structurally-valid
  no-op DTBO table (not simply truncated/corrupted) to avoid ABL's `ufdt`
  overlay-application logic trying to apply a downstream DTBO onto a
  mainline DTB. **Unverified assumption**, inherited from the X910
  reference — X716's ABL, being from the 5G SKU, could plausibly differ.
- **`vbmeta`** — already has AVB flags=2 (verification disabled), confirmed
  by direct header inspection (see `docs/hardware-facts.md`). **No vbmeta
  rewrite is planned or should be needed** — this was the single
  highest-risk step in earlier iterations of this plan, and it's already
  resolved in our favor. Do not touch this partition.

The first flash attempt is the real test of the two "unverified assumption"
items above. Expect to learn something from it regardless of outcome.

## Pre-flash checklist (follow every time, no exceptions)

1. Confirm the tablet is in TWRP and reachable: `adb devices` shows it in
   `recovery` mode, not normal Android.
2. Take a fresh TWRP nandroid backup of at minimum `boot`, `init_boot`,
   `vendor_boot`, `dtbo`. A backup from 2026-09-04 already exists in this
   working directory's sibling folder — confirm it's still the most recent
   before relying on it, or take a new one.
3. `adb pull` the backup off-device. Verify each file's size against
   `docs/hardware-facts.md`'s partition table and its `.md5` sidecar.
4. Record the backup's location and a fresh `sha256sum` of each file as the
   "last verified rollback point" in `docs/hardware-facts.md`.
5. **Stop here and get explicit confirmation** naming the exact
   partition(s) about to be written and the rollback plan, before running
   any `dd` command. This applies to every single flash, not just the
   first — never batch multiple flashes into one unconfirmed sequence.

## Flashing mechanics

- `fastboot` is not usable on this device family. All flashing goes through
  TWRP + `adb shell dd` to raw block devices (`/dev/block/by-name/<name>`).
- After writing, read the partition back and `sha256sum` it against the
  source image before considering the write successful or rebooting.
- Write order when multiple partitions change together: anything that
  isn't the currently-relied-upon boot path first, `boot`/`vendor_boot`
  last — so an interrupted sequence never leaves the device with no
  bootable kernel at all. (Phase 4 will add: rootfs image before boot
  images, for the same reason.)

## Post-flash: reading results back with no display and no UART

There is no UART cable and, until Phase 3 succeeds, no display. The primary
signal is the `sec_log_buf_region` carveout (`0x8_80200000`, see
`docs/hardware-facts.md`) — Samsung's own persistent kernel-log region,
which TWRP is a known consumer of for `/proc/last_kmsg`-style readback
after a hang or reboot. Plan:

1. Port a small console driver (`kernel/drivers/samsung-x716-sec-log.c`)
   that registers as a kernel console and writes into this region.
2. **Validate the readback mechanism itself works on this unit using the
   *stock* Samsung kernel first**, before depending on it to debug a
   mainline kernel that might not even reach the point of writing anything.
3. Two-stage signal to look for after a flash + reboot:
   - (a) uniLoader's own splash/console message (if it has a route to
     write somewhere readable before jumping to Linux) — proves ABL
     executed the custom image at all, independent of whether Linux itself
     boots.
   - (b) sec-log evidence that the mainline kernel executed, even if it
     then panics or hangs.

Kernel cmdline for early bring-up carries heavy debug flags:
`earlycon loglevel=8 log_buf_len=4M panic=10 clk_ignore_unused
pd_ignore_unused regulator_ignore_unused initcall_debug` — `panic=10`
specifically so a panic auto-reboots after 10s rather than requiring a
manual power-button recovery between every iteration.

## Sec-log readback: confirmed working (2026-09-05)

Validated end-to-end directly on this tablet, read-only, no flashing: on
stock Android, `/proc/last_kmsg` exists at exactly 2,097,136 bytes
(`0x200000` region size minus the 16-byte header — an exact independent
confirmation of the driver's size math). After `adb reboot recovery`, TWRP
also exposed `/proc/last_kmsg` at the same size, showing stock Android's
own late-session log content — i.e. **TWRP successfully read back
sec_log_buf content written by a different kernel from the previous boot**,
which is exactly the mechanism this project's whole console-less debug
strategy depends on. This is no longer an assumption. See
`docs/hardware-facts.md` for the full detail.

**Gotcha found while testing**: a plain `adb reboot` issued from *within*
TWRP cycles back into recovery again rather than continuing to a normal
system boot — use `adb reboot system` explicitly to actually leave
recovery.

## Recovery if something goes wrong

TWRP + `adb` first (the backup from the pre-flash checklist restores the
exact prior state). If TWRP itself becomes unreachable, Download Mode +
Odin with official firmware is the fallback — not yet needed, and not
attempted unless TWRP access is actually lost.
