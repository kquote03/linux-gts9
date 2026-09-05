# Boot strategy

How this port gets a custom kernel running on the Samsung Galaxy Tab S9 5G
(SM-X716B), and the safety procedure every device-write step must follow.
See `docs/hardware-facts.md` for the underlying data this document cites.

## The boot chain (validated 2026-09-05, attempt 8)

No secondary bootloader is used. uniLoader (`github.com/ivoszbg/uniLoader`)
was tried across five flash attempts and dropped — see "History: how we
got here" below for why. The mainline kernel boots directly, via Samsung's
stock ABL, following the recipe validated on `ubuntu-galaxy-tab-s9ultra`
(the SM-X910 Ultra port — the same SM8550 "kalama" chip generation as this
device). Confirmed on real hardware: attempt 8 produced genuine mainline
`Linux version 7.2.0-dirty` boot text, all 8 CPUs online, and our own
sec-log console driver registering successfully.

Samsung's stock bootloader (ABL) loads, per the by-name partition map:

- **`boot`** — the "kernel" slot, built by `scripts/build-android-v4-bundle.sh`.
  Contents: the mainline kernel `Image`, **gzip-compressed**, with the
  board DTB **concatenated directly after** the compressed stream (the
  classic ARM64 "Image.gz-dtb" appended-DTB convention). No ramdisk here —
  `init_boot` supplies it (GKI-style split). Two things this must get
  right, both confirmed by direct evidence in attempt 6/8's own
  `/proc/last_kmsg` captures:
  - **Gzip, not raw.** ABL's own log unconditionally shows a
    `"Decompressing kernel image"` step regardless of what's in the slot —
    a raw uncompressed `Image` was never going to work here.
  - **DTB appended, not just referenced elsewhere.** This matches the
    validated X910 recipe exactly; `vendor_boot` also carries a copy (see
    below), and which one ABL actually applies is answered by the next
    bullet.
- **`init_boot`** — the generic ramdisk (GKI 2.0 style), in **legacy LZ4**
  framing, not gzip. Confirmed necessary from the X910 recipe's own script
  comment: a gzip generic ramdisk is a valid Android v4 image but Linux
  rejects the resulting initrd with `"invalid magic at start of compressed
  archive"` on this boot chain. `scripts/build-android-v4-bundle.sh`
  detects the bring-up ramdisk's format and converts gzip → legacy LZ4
  automatically.
- **`vendor_boot`** — the board DTB, kernel cmdline, and the same LZ4
  ramdisk (as a redundant vendor-side copy; not currently used for
  anything `init_boot`'s copy doesn't already cover). `--base
  0x80000000 --kernel_offset 0x8000 --ramdisk_offset 0x02000000
  --tags_offset 0x01e00000 --dtb_offset 0x1f00000 --pagesize 4096` — these
  offsets match the stock vendor_boot header measured from the 2026-09-04
  TWRP backup, and also match the X910 reference exactly. **This is the
  DTB ABL actually applies** — confirmed by attempt 8's kernel successfully
  parsing our board devicetree (regulators, UFS, sec-log's reserved-memory
  node all resolved correctly at boot).
- **`dtbo`** — a **4096-byte all-zero blob**, deliberately **not** a valid
  Android DT table. This is the actual fix for the root cause that
  produced six consecutive silent failures (`"No Valid Dtb"` — see
  "History" below): any structurally-valid DT table, empty or not, makes
  ABL take its downstream `ufdt` overlay-merge path and reject a mainline
  base DTB outright. A blob with no DT-table magic at all makes ABL skip
  that path and use `vendor_boot`'s DTB directly, unmerged. Confirmed
  fixed: attempt 8's `/proc/last_kmsg` capture has zero occurrences of
  `"No Valid Dtb"`, versus 100% (6/6) of prior attempts.
- **`vbmeta`** — already has AVB flags=2 (verification disabled), confirmed
  by direct header inspection (see `docs/hardware-facts.md`), and now
  independently reconfirmed working for all four boot-chain partitions
  across every attempt (`AUTHENTICATE fail but allow` logged for
  `boot`/`vendor_boot`/`init_boot`/`dtbo`). **No vbmeta rewrite is needed.**
  Do not touch this partition.

## History: how we got here

1. **Attempts 1–5 (uniLoader)**: uniLoader was adopted as an intermediate
   bootloader, modeled on `sm-x800-linux`'s Tab S8+ port (a different,
   older SM8450 SoC generation) where it's required because ABL's DTBO
   fragments corrupt a mainline DTB. Every attempt fell back to Download
   Mode. Extensive debugging (checkpoint instrumentation in uniLoader's
   own relocation code, `TEXT_BASE` matching, gzip-vs-plain) found zero
   signal every time.
2. **Attempt 6 (raw kernel `Image`, no uniLoader)**: dropped uniLoader to
   remove a variable. Failed identically. This time the *entire*
   `/proc/last_kmsg` capture was read line-by-line instead of grepped for
   expected markers, and it revealed the real failure, present identically
   in **all six** attempts so far: `"No Valid Dtb" / "Unable to find the
   Board Dtb" / "Error: Board Dtbo blob not found"`, immediately followed
   by ABL launching Odin — **before ABL ever touches the kernel payload
   slot**. Every earlier "uniLoader crashed after Exit Boot Services"
   observation was a misattribution: that log content belonged to ABL's
   automatic fallback boot into `recovery` (TWRP) after this exact error,
   not to our own attempt.
3. **Attempt 7**: fixed a real structural bug in the DTBO builder (a
   missing 8th header field, misaligning every entry by 4 bytes) — an
   insufficient fix. Still failed identically: a *correctly-formed* empty
   DT table is still a DT table, and any DT table triggers ABL's rejection
   path.
4. **The actual fix, found by comparing against `ubuntu-galaxy-tab-s9ultra`**
   (the X910 Ultra port — the same chip generation as this device, already
   proven on real hardware): its own `validate-bundle.sh` asserts, by
   name, that a `dtbo.img` whose first 4 bytes parse as the DT table magic
   fails the build, with exactly our error text quoted in the check's
   failure message. Its recipe: a zero-filled `dtbo.img`, kernel gzip'd
   with the DTB appended, generic/vendor ramdisks in legacy LZ4. Adopting
   this recipe verbatim is **attempt 8**, and it worked: no more Download
   Mode, no more `"No Valid Dtb"`, genuine mainline kernel boot text.
5. **Attempt 8's new failure, fixed by `gpio-reserved-ranges`**: the kernel
   booted deep into real hardware bring-up (SMEM, all 8 CPU power domains,
   several interconnect providers) then hit a **silent hard reset** — no
   Oops/panic text, just a cold PMIC reset — immediately after the last
   interconnect probe. Matched a failure mode already flagged in
   `kernel/dts/sm8550-samsung-x716b.dts`'s own comments: pinctrl-msm's
   TLMM probe touching a TrustZone-locked GPIO. Fixed in attempt 10 with
   `gpio-reserved-ranges = <36 4>` (GPIOs 36-39, the fingerprint sensor's
   SPI bus) — confirmed via `ubuntu-galaxy-tab-s9ultra` using the identical
   reservation, and independently via X716's own stock DTS agreeing with
   X910 on the same `pm8550_gpios "gpio12"` pin for an unrelated purpose,
   evidence the two boards' PMIC/pin wiring is close enough to trust.
6. **The kernel is confirmed alive, deep into boot**: after the
   `gpio-reserved-ranges` fix, the hard-reset loop stopped, replaced by a
   silent black screen requiring a manual reset — and reading that back
   via `/proc/last_kmsg` turned out to be effectively impossible (see
   `docs/porting-log.md`'s "the diagnostic channel hits a hard capacity
   wall" for why). The decisive test instead: a `gpio-leds` node with
   `linux,default-trigger = "heartbeat"` on GPIO 18 (this device's own
   ABL-log-confirmed vibrator motor GPIO) — **the tablet physically
   vibrates in a heartbeat pattern**, a purely kernel-side signal (runs off
   a kernel timer) that needs no log capture at all. The kernel is
   genuinely alive, with working GPIO/pinctrl/regulators/timers, not
   crashed or deadlocked.
7. **Userspace/PID 1 confirmed reached — Phase 3's exit criterion is met.**
   The kernel-side heartbeat alone didn't prove this: it would keep
   blinking even if the kernel were permanently stuck in the deferred-probe
   mechanism (not a bug — the kernel retrying forever by design — so
   neither `hung_task` nor a panic would ever catch it). A full USB
   Type-C gadget stack (matching X910's real, working setup: `sm5714`
   TCPM + `ps5169` redriver + `ptn3222` repeater) was built to get an
   interactive shell, but failed to enumerate at all — and rather than
   keep guessing at that independently, `fw_devlink=off
   deferred_probe_timeout=10` was tried first (zero change — ruled out a
   deferred-probe deadlock) and then the bring-up ramdisk's own `/init`
   was changed to repurpose the same GPIO-18 vibrator itself, the instant
   userspace starts: a burst of 5 fast pulses, unmistakably different from
   the kernel's own steady heartbeat. **The burst was felt.** This is
   direct, physical, real-time proof — independent of any log capture —
   that `/init` genuinely runs. The USB gadget's failure to enumerate is
   now understood to be an isolated, non-boot-blocking problem in its own
   newly-added devicetree wiring, not a sign of a stuck system.

uniLoader is **not deleted** (`uniloader-overlay/`, `scripts/fetch-uniloader.sh`,
`scripts/build-uniloader.sh` remain in the repo, unused) but is confirmed
unnecessary for this SoC generation — the X910 sibling proves direct
mainline boot works on the exact same chip family without it.

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

There is no UART cable, and no display driver exists yet. The signal path
is the `sec_log_buf_region` carveout (`0x8_80200000`, see
`docs/hardware-facts.md`) — Samsung's own persistent kernel-log region,
which TWRP is a known consumer of for `/proc/last_kmsg`-style readback
after a hang or reboot. This is no longer a plan — it's a working,
twice-confirmed mechanism:

1. `kernel/drivers/samsung-x716-sec-log.c` is a from-scratch Linux console
   driver (written after reading, not copying, Samsung's downstream
   format) that registers as a kernel console and writes into this region.
2. **Confirmed working with the stock kernel first** (2026-09-05, before
   any custom flashing): stock Android → TWRP round-trip showed TWRP
   correctly reading back a different kernel's previous-boot log at the
   exact expected size.
3. **Confirmed working with our own mainline kernel** (2026-09-05, attempt
   8): `/proc/last_kmsg` showed `x716-sec-log log-buf: sec-log console
   registered (2097136 byte ring buffer)` — our driver's own registration
   message, read back via TWRP after the device power-cycled. This is the
   primary diagnostic channel for all Phase 3 iteration from here on.

**Reading the capture requires care**: the underlying region is a
modulo-wrapping ring buffer shared across power cycles, and a bootloop
(several power-on attempts before TWRP settles) means one capture can
contain interleaved fragments from multiple boot attempts. Don't just grep
for expected markers — read enough of the file in order, and use
`AST_POWERON` / `Linux version` / `SetDdiKernelType` as landmarks to figure
out which segment belongs to which boot attempt before drawing conclusions
from a match (or a non-match). Attempts 1–6's "uniLoader crashed after Exit
Boot Services" conclusion was exactly this mistake — that content actually
belonged to a *different* boot cycle (ABL's automatic fallback into
`recovery`), not to the attempt being diagnosed.

Kernel cmdline for early bring-up carries heavy debug flags:
`earlycon loglevel=8 log_buf_len=4M panic=10 clk_ignore_unused
pd_ignore_unused regulator_ignore_unused initcall_debug` — `panic=10`
specifically so a panic auto-reboots after 10s rather than requiring a
manual power-button recovery between every iteration.

**Gotcha found while testing**: a plain `adb reboot` issued from *within*
TWRP cycles back into recovery again rather than continuing to a normal
system boot — use `adb reboot system` explicitly to actually leave
recovery.

## Recovery if something goes wrong

TWRP + `adb` first (the backup from the pre-flash checklist restores the
exact prior state). If TWRP itself becomes unreachable, Download Mode +
Odin with official firmware is the fallback — not yet needed, and not
attempted unless TWRP access is actually lost.
