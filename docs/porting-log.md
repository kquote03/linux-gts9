# Porting log

A dated, session-by-session engineering diary. Each entry records what was
attempted, what passed/failed, and any log excerpts — so a future session
can resume without repeating dead ends. See `docs/hardware-facts.md` for the
ground-truth reference this log cites instead of re-deriving facts, and
`docs/boot-strategy.md` (once written, Phase 2) for the safe-flashing
procedure.

---

## Session 1 — 2026-09-04

Kicked off the project. No device-write actions taken this session — all
work was research, planning, and off-device Phase 0 setup.

**Research** (three parallel Explore agents, then direct `adb`/root-shell
inspection of the physical tablet):

- Confirmed the target SoC is Qualcomm Snapdragon 8 Gen 2 (SM8550, "kalama")
  by reading `android_kernel_samsung_gts9`'s build config and DTS — this is a
  GKI 5.15.153 downstream kernel, not Exynos.
- Parsed the TWRP nandroid backup's boot image headers by hand (no
  `unpack_bootimg` available at the time) to get ground-truth partition sizes
  and boot image format (header_version 4 throughout).
- Read `ubuntu-galaxy-tab-s9ultra` (the sibling SM-X910 Ultra port) as an
  architectural template — noted its DTS include strategy, kernel-config
  philosophy (everything critical built statically), and stock-ABL boot
  chain approach, while flagging every SM-X910-specific detail (panel, touch,
  PMIC rail names, no-modem) as needing independent re-verification on X716.
- Connected to the physical tablet directly via `adb` (currently booted to
  stock Android 15, Magisk-rooted, not TWRP) and confirmed several facts that
  meaningfully changed the plan:
  - **vbmeta already has AVB flags=2 (verification disabled)** — manually
    parsed the AVB header at `/dev/block/by-name/vbmeta`. This removes what
    would otherwise have been the single highest-risk step (getting AVB
    verification disabled without bricking the device).
  - **Zero free space on internal storage** — the main UFS LU is fully
    partitioned; `userdata` alone is ~107 GB, 93% full. Ruled out any
    "carve a new partition into free space" approach.
  - **A 238 GB exFAT microSD card is present and mounted** — became the
    Phase 4 MVP rootfs target instead of internal storage, to avoid
    repartitioning risk before the kernel is proven stable.
  - Full `by-name` partition map, confirming no A/B slots and matching the
    TWRP backup's partition sizes exactly.
- At the user's request, investigated `github.com/ivoszbg/uniLoader`
  (postmarketOS-community secondary bootloader project) as a boot-chain
  tool. Read its actual source (not just the wiki blurb) and found: it has
  no existing support for SM8550/kalama or any modern Qualcomm SoC (only
  `msm8916`, 2015-era); it embeds kernel+ramdisk as compiled-in blobs and
  still relies on ABL to supply the DTB externally, so it does **not**
  remove the plan's existing DTB/ABL-quirk risks — but it does give an
  earlier, simpler "did ABL even run our image" checkpoint via its own tiny
  console, before Linux's own more fragile early boot. Folded into the plan
  as an additional layer, not a replacement for the DTS work.

**Phase 0 work completed and committed** (see git log for exact commits):

1. `git init`, `.gitignore` (excluding the three reference inputs, build
   scratch, and binary artifacts), `README.md` stating scope/non-goals.
2. `docs/hardware-facts.md` — the ground-truth reference doc, with every
   fact tagged measured/inherited/assumed.
3. `shell.nix` — verified by actually entering the shell and running every
   tool, not just checking the derivation evaluates. Notable snags found and
   fixed: `mmdebstrap` isn't packaged in this nixpkgs snapshot (falling back
   to `debootstrap`, already planned as a fallback); `kpartx` comes from
   `multipath-tools`, not a standalone package; `qemu_full` pulls in a huge
   unrelated dependency tree (ceph/arrow/glusterfs/azure-sdk) — swapped for
   the much leaner `qemu-user`.
4. `third_party/android-tools/` — vendored `mkbootimg.py`/`unpack_bootimg.py`/
   `repack_bootimg.py`/`avbtool.py` from pinned AOSP commits (recorded in
   `PROVENANCE.md`). Verified both run standalone under plain `python3`.
5. `scripts/fetch-uniloader.sh` — pins uniLoader at commit `2418e066`.
   Tested: clone, pin-verify, and idempotent re-run all work.
6. This file.

**Next session should start at**: Phase 1 — kernel source pin
(`scripts/fetch-mainline.sh`), the X716 board DTS, kernel config fragment,
and the uniLoader SoC/board overlay. No device contact needed until Phase 2.

---

## Session 2 — 2026-09-05

Completed Phase 1 in full: mainline kernel builds, board DTB compiles
cleanly, uniLoader builds embedding both. No device contact — everything
below is off-device build work. Also incorporated uniLoader into the plan
at the user's request (researched it properly by reading its actual source
rather than the wiki page, which was blocked by an anti-bot challenge).

**uniLoader investigation**: read `main/boot.c`, `main/main.c`,
`arch/aarch64/load-kernel.c`, `soc/qualcomm/msm8916.c`,
`board/samsung/board-j5lte.c`, and the CI build script directly. Corrected
an initial research finding — uniLoader actually already has Kconfig
entries for `SM8350`/`SM8450`/`SM8650`/`SM8850` (just no `.c` backend files
for any of them, since `soc_init()` turns out to have no call site anywhere
in the codebase despite being `extern`-declared), not just the ancient
`msm8916`. `SM8550` (our exact chip) was the one gap in that range. Also
found `arch/arm64/boot/dts/qcom/sm8550-samsung-q5q.dts` already exists in
mainline Linux (Samsung Galaxy Z Fold5, real accepted-upstream board) while
checking kernel tag `v7.2` for SM8550 devicetree support — used it as the
structural template for our own board DTS and to cross-validate facts
pulled from X716's downstream source (console UART, UFS regulator rail
indices and reset GPIO all confirmed via independent cross-checks — see
`docs/hardware-facts.md`).

**Kernel + DTS** (`kernel/dts/sm8550-samsung-x716b.dts`,
`kernel/config/config-{mainline.aarch64,x716.fragment}`,
`scripts/fetch-mainline.sh`, `scripts/build-mainline-kernel.sh`): pinned
mainline `v7.2` (full stable release). First DTS compile attempt caught two
real DT bugs (regulator labels aren't provided by `pm8550*.dtsi` and must
be board-defined; deleting reserved-memory nodes without redefining them
under the same label breaks phandle references in `sm8550.dtsi`'s
remoteproc nodes — fixed by not deleting them at all, since the
corresponding remoteproc nodes already default to `status = "disabled"`).
Config fragment work found `CONFIG_PINCTRL_SM8550` entirely absent from
defconfig (off by default) — would have been a silent boot-blocker since
it's this SoC's TLMM pin controller.

**Toolchain debugging** — getting an actual kernel build green on this dev
machine took five rounds of reproduce-isolate-fix, all recorded in
`docs/hardware-facts.md`'s "Toolchain gotchas" section: `HOSTCC`/`HOSTCXX`
must be passed on the `make` command line (env export alone doesn't survive
Kbuild's `LLVM=1` handling); bare `clang-unwrapped` needs an explicit
`-resource-dir` **and** `-isystem` (not just the former) to find its own
builtin headers under the kernel's `-nostdinc`; `CONFIG_DEBUG_INFO=y`
(defconfig's default) made the final `vmlinux.o` link step OOM-kill twice
in a row on this shared 14 GB machine regardless of `-j` parallelism (the
link step is a single unparallelizable process, so reducing `-j` doesn't
help — only turning off debug info did); uniLoader's own build needed
`ARCH=aarch64` and the same `HOSTCC`/`HOSTCXX` fix passed explicitly,
since `shell.nix`'s kernel-build-oriented `ARCH=arm64`/`LLVM=1` exports
otherwise leak in and break it.

**uniLoader overlay** (`uniloader-overlay/`, `scripts/build-uniloader.sh`):
new `SM8550` SoC Kconfig entry (no `.c` backend, per the finding above) and
a minimal `board-gts9-5g.c` (no `early_init`/`late_init`/framebuffer —
confirmed both hooks are genuinely optional). `TEXT_BASE`/`PAYLOAD_ENTRY`/
`RAMDISK_ENTRY` in `gts9-5g_defconfig` are a reasoned first-attempt guess
(0xa8000000/0xb8000000/0xc8000000), adopted from the closest real working
precedent (`configs/pong_defconfig`, Nothing Phone 2 on SM8450) rather than
independently derived — flagged clearly as needing Phase 2/3 hardware
verification, not treated as confirmed fact. Also caught and fixed a real
`awk` insertion bug of my own: the `soc/Kconfig` patch was appending the
new entry after just the `config SM8650` header line instead of before the
whole block, orphaning SM8650's own body — found via a Kconfig warning,
fixed, verified clean via a fresh re-fetch + rebuild.

**Result**: kernel `Image` (42 MB) + DTB (115,635 B) + uniLoader
(43,536,384 B, embedding both plus the bring-up ramdisk) all build
successfully. Exact hashes in `docs/hardware-facts.md`. Phase 1 exit
criterion met — nothing has touched the physical device yet.

**Next session should start at**: Phase 2 — `docs/boot-strategy.md`, the
pre-flash backup checklist, deciding which uniLoader artifact (plain vs.
`.gz`) to package, `scripts/build-android-v4-bundle.sh`, the sec-log
console driver, and the first actual flash attempt. This is where the
plan's explicit per-step user confirmation requirement starts applying to
every device-write action.

---

## Session 3 — 2026-09-05

Started Phase 2 prep work (still no device contact). Wrote
`docs/boot-strategy.md` (boot chain explanation with uniLoader in the loop,
mandatory pre-flash checklist, flashing mechanics, recovery plan).

**sec-log driver**: rather than guess the on-disk format, read Samsung's
actual GPL-licensed downstream driver source directly (already present in
this working directory under `android_kernel_samsung_gts9/`) —
`drivers/samsung/debug/log_buf/sec_log_buf_main.c` and the public
`sec_log_buf.h` header gave the exact struct layout (`boot_cnt`/`magic`
`0x4d474f4c`/`idx`/`prev_idx`/`buf[]`), the real devicetree compatible
string (`samsung,kernel_log_buf`, a separate consumer node referencing the
carveout via `memory-region`, not the reserved-memory node itself), and the
modulo-wrapping ring-buffer write algorithm. Wrote a from-scratch, much
simpler reimplementation (`kernel/drivers/samsung-x716-sec-log.c`) covering
only the write side — none of Samsung's compression/debugfs/kprobe/ap_klog
machinery, which this bring-up doesn't need. Added the matching `log-buf`
consumer node to the board DTS, a `CONFIG_X716_SEC_LOG` Kconfig entry
(inserted into `drivers/misc/Kconfig`/`Makefile` by
`scripts/build-mainline-kernel.sh`, same idempotent-patch pattern already
used for the uniLoader overlay), and enabled it in `config-x716.fragment`.

Rebuilt the kernel + DTB + uniLoader end to end with the driver included —
all three still build cleanly (`drivers/misc/x716-sec-log.o` compiles with
no errors or warnings). New artifact hashes recorded in
`docs/hardware-facts.md`, which now also documents the driver's real
limitation honestly: it probes at roughly `arch_initcall` time, so a hang
earlier than that (plausible, given the UFS/regulator/pinctrl risk already
flagged) would leave this channel with nothing captured.

**Result**: kernel + DTB + uniLoader all still build successfully with the
sec-log driver included. Still nothing has touched the physical device.

**Next session should start at**: the remaining Phase 2 items —
`scripts/build-android-v4-bundle.sh` (mkbootimg/avbtool packaging, still
needs a decision on plain vs. `.gz` uniLoader artifact), `scripts/
flash-boot-set.sh`, validating the sec-log readback path with the *stock*
kernel first, and then — with explicit per-step confirmation — the first
actual flash attempt.

**Continued same session**: wrote and tested both remaining scripts.

`scripts/build-android-v4-bundle.sh` packages uniLoader as `boot.img`'s
kernel (no ramdisk — GKI-style split), the bring-up ramdisk into
`init_boot.img`, the board DTB + vendor cmdline + the same ramdisk into
`vendor_boot.img` (base/offsets matching the stock header), and a
hand-built inert single-entry DTBO table into `dtbo.img` (`mkdtboimg.py`
wasn't vendored, so the well-documented header format is built directly in
Python). All four get an unsigned, structural-only avbtool footer
(`--algorithm NONE` — appropriate since vbmeta verification is already
disabled). Verified thoroughly before trusting it: all four images came out
to exactly the confirmed stock partition sizes, and `avbtool info_image` /
`unpack_bootimg.py` both confirm the internal structure (load addresses,
DTB, cmdline, ramdisk size) matches what was specified, and the hand-built
DTBO header parses correctly against the documented format.

`scripts/flash-boot-set.sh` — the only device-write script in this repo.
Refuses to run without an explicit acknowledgement flag, checks the device
is actually in TWRP, verifies image sizes before writing, and reads back +
sha256-verifies after every write. Tested only the safety guard and
argument handling (no device attached to this check) — **not run against
the physical tablet**.

**Result**: Phase 2's off-device prep work is now complete —
`docs/boot-strategy.md`, the sec-log driver, the boot-image packaging
script, and the flashing script all exist and are individually verified as
far as possible without touching the device. What's left all requires
actual device interaction: validating the sec-log readback path with the
*stock* kernel first (a reboot into TWRP + a read, not a flash, but still
device interaction beyond what this session did unprompted), then — with
fresh backups and explicit per-step confirmation — the first real flash
attempt with the custom boot chain.

**Next session should check in before any further device interaction**,
starting with the stock-kernel sec-log validation step.

**Continued same session, with explicit go-ahead**: performed the
stock-kernel sec-log validation directly on the tablet. Checked
`/proc/last_kmsg` on stock Android first (no reboot needed) — exists,
exactly 2,097,136 bytes, matching the driver's size calculation exactly.
Then `adb reboot recovery` → TWRP → **`/proc/last_kmsg` also present there,
same exact size, showing stock Android's own prior-session log content** —
direct proof that TWRP can read back sec_log_buf data written by a
different kernel across a reboot, which is the entire premise this
project's console-less debug strategy rests on. Then `adb reboot system`
back to normal Android (a plain `adb reboot` from within TWRP turned out to
just cycle back into recovery instead of continuing to system boot — noted
in `docs/boot-strategy.md`). Device confirmed back to normal stock Android,
fully booted.

**Result**: the sec-log readback mechanism is now confirmed working on
this exact unit, not an assumption inherited from the X910 reference. This
was the last open item before an actual flash attempt makes sense. Updated
`docs/hardware-facts.md`'s open-risks list and `docs/boot-strategy.md`
accordingly.

**Next session should check in before the first flash attempt** — the
remaining Phase 2/3 unknowns (ABL's DTB source, whether it accepts the
custom boot chain at all) can only be resolved by actually flashing, which
needs a fresh backup and explicit per-partition confirmation per
`docs/boot-strategy.md`.

**Continued same session, with explicit go-ahead**: took the pre-flash
backup. Rebooted to TWRP (`adb reboot recovery`, plus one extra USB
reconnect TWRP does itself between its splash screen and menu — noted for
future sessions), `dd`'d `boot`/`init_boot`/`vendor_boot`/`dtbo` to device
tmpfs (`/tmp`, not `/data`, to avoid any interaction with the encrypted
userdata partition), hashed them on-device, pulled all four off with `adb
pull`, and confirmed the local copies hash-match the on-device dump
exactly before deleting the on-device tmpfs copy. All four sizes match the
confirmed stock partition sizes. Recorded as the current "last verified
rollback point" in `docs/hardware-facts.md`. Stored at
`backups/2026-09-05/` (gitignored).

Device is currently sitting in TWRP, untouched otherwise.

**Next: the actual first flash attempt**, checking in for explicit
per-partition confirmation before running `scripts/flash-boot-set.sh`.

**Continued same session, with explicit go-ahead**: ran the first flash.
`scripts/flash-boot-set.sh` wrote `boot` (uniLoader, uncompressed variant),
`init_boot` (bring-up ramdisk), `vendor_boot` (board DTB + debug cmdline +
same ramdisk), and `dtbo` (inert no-op table) — all four confirmed via the
script's own push→dd→readback→sha256 verification, no mismatches. Device
is sitting in TWRP with the custom boot chain flashed, not yet rebooted
into it.

**Next: the actual first boot attempt** — checking in before triggering
the reboot, since this is genuinely the first time this exact combination
gets to run on real hardware and the outcome (does ABL even accept it, do
we get any sec-log signal) is unknown. Rollback point is
`backups/2026-09-05/` if it doesn't come back.

**Continued same session, with explicit go-ahead**: triggered the reboot.
ABL fell back to Download Mode almost immediately — not a brick, a
recoverable Samsung safety fallback. User manually exited Download Mode
(button combo) back to TWRP. Pulled the full sec-log capture
(`work/bringup-2026-09-05/last_kmsg-attempt1.txt`, 2,097,136 bytes) for
diagnosis.

**Root-caused it from the log, not guessed**: ABL's own log line
`LinuxLoader Load Address to debug ABL: 0xC44C9000` shows it dynamically
loaded uniLoader at `0xC44C9000` — completely unrelated to the
vendor_boot header's legacy `kernel_addr` field we'd set (`0x80008000`),
confirming ABL ignores that field on this device. uniLoader's own
"position independent" mode (`arch/aarch64/reloc.S`) turned out to not be
true PIC: it self-copies its entire ~43 MiB from wherever it's actually
running to the Kconfig-compiled `TEXT_BASE`, forward-only, not
overlap-safe. Our guessed `TEXT_BASE=0xa8000000` (borrowed from an
unrelated device, Nothing Phone 2) forced that copy to run for no reason,
and the log's last line before the crash is ABL's own "Exit Boot
Services" — consistent with a crash during or right after that copy.
Also separately confirmed from the same log: the vbmeta
flags=2/verification-disabled bypass works exactly as intended
(`AUTHENTICATE fail but allow ... binary: vbmeta`, `verifystatus(2)`).

**Fix**: set `TEXT_BASE=0xC44C9000` in `gts9-5g_defconfig` — the exact
measured address — so the relocation comparison succeeds and the risky
self-copy never happens. Verified directly: `readelf -h uniLoader.o` now
shows `Entry point address: 0xC44C9000`, matching exactly. Checked
`PAYLOAD_ENTRY`/`RAMDISK_ENTRY` (unchanged) against this new address and
against ABL's own logged available-memory regions — no overlap either
direction. Rebuilt uniLoader and the full boot-image bundle with the fix.
Full detail in `docs/hardware-facts.md`.

**Next: second flash attempt** with the corrected `TEXT_BASE` — checking
in before flashing/rebooting again.

**Continued same session, with explicit go-ahead**: second attempt also
fell back to Download Mode. User checked directly from the device screen
this time (Download Mode UI, no need to poll adb). Pulled the fresh
capture (`last_kmsg-attempt2.txt`) — and it revealed something important:
**the "LinuxLoader Load Address" is not stable.** This boot alone logged
it twice with two different values (`0xC44C6000` then `0xC44D0000`,
between what look like two automatic ABL retries within the same power-on
session — "Loader Build Info"/"ONEUI VER" reprinted, a fresh ABL
invocation banner), neither matching attempt 1's `0xC44C9000` or our
newly-set `TEXT_BASE`. **Hardcoding a specific measured address is not a
viable long-term fix — the previous session's approach only happened to
be directionally right, not actually correct.**

Since we have zero visibility into whether uniLoader's own code runs at
all after ABL's "Exit Boot Services" handoff (ABL's log ends there either
way; uniLoader has no logging hooked up by default), added two bring-up
diagnostic checkpoints to `uniloader-overlay/board-gts9-5g.c` — using the
`early_init`/`late_init` hooks `main()` already calls, so no upstream
uniLoader files need patching. Each writes a distinct marker string
directly into the same physical sec_log_buf region/format the mainline
kernel's own driver uses, so checkpoint text will show up in
`/proc/last_kmsg` via TWRP exactly like real kernel console output would:
- `early_init`: fires right after `main()`'s `early_console_init()` — if
  this shows up, self-relocation and the jump into uniLoader's C code
  definitely worked.
- `late_init`: fires after `driver_probe_all`/`print_splash`, right before
  `boot_kernel()` (DTB patching + the final jump to the real kernel) — if
  this shows up but the kernel itself never produces sec-log output, the
  problem is narrowed to `boot_kernel()`/`arch_load_kernel()` specifically.

Rebuilt uniLoader and the bundle with this change (`TEXT_BASE` left at the
previous `0xC44C9000` — its exact value matters less now, the checkpoints
will tell us directly whether the self-relocation path is even the
problem).

**Next: third flash attempt**, checking in before flashing/rebooting.

**Continued same session, with explicit go-ahead**: third attempt also
fell back to Download Mode. Pulled `last_kmsg-attempt3.txt` — **neither
checkpoint marker appeared at all.** Confirmed this was the right boot's
data (same "Exit EBS...UEFI End" tail, three more "LinuxLoader Load
Address" retries logged, none matching `TEXT_BASE` again). Since
`early_init` is called from `main()`, and `main()` is only reached *after*
uniLoader's self-relocation code finishes and jumps there, zero signal
from even the first checkpoint means **execution never reaches `main()`
at all** — the failure is in the relocation copy itself (`arch/aarch64/
reloc.S`) or earlier.

Patched `reloc.S` directly (`uniloader-overlay/reloc.S`, installed via
full-file replacement in `scripts/build-uniloader.sh`, same pattern as
the board file) with two raw-assembly checkpoints, since this code runs
before any C runtime or valid stack exists: checkpoint A ("CKPA") right
at `_reloc_entry`'s start, checkpoint B ("CKPB") right before the final
jump to `_start` (reached either via the same-address shortcut or after
the copy loop). Both explicitly set the sec_log header's `magic`+`idx`
fields (not just poke a byte pattern), since `/proc/last_kmsg` only
exposes `buf[0..idx)` — a poke without updating `idx` would be invisible
even if it executed, a mistake caught and fixed before flashing anything.
Verified: builds and assembles cleanly, `readelf -h uniLoader.o` still
shows the expected entry point.

**Next: fourth flash attempt**, checking in before flashing/rebooting.
If CKPA shows up, the relocation entry itself is reached; if CKPB also
shows up, the copy (or same-address shortcut) completed and the jump to
`_start` was attempted. If neither shows up again, the problem is even
earlier than this file — possibly the ARM64 Image header itself being
rejected by ABL, or the initial branch to `_head` failing outright.

**Continued same session** (user gave a standing go-ahead to stop asking
before each flash/reboot from here on — still needs the user's eyes on
the physical screen for Download Mode, which isn't adb-visible). Fourth
attempt: still zero checkpoint signal, even from the raw-assembly
checkpoint at `_reloc_entry`'s literal first instruction. Verified via
`objdump` that the compiled/linked code exactly matches intent — no
encoding bug.

Noticed something new while investigating: every attempt's ABL log shows
`LinuxLoaderEntry Address` = `Load Address + 0xB3C`, exactly, every time,
regardless of the (varying) load address. Tested whether this reflects a
gzip-wrapper expectation (uniLoader's own default also builds a
`uniLoader.gz` — a previously-flagged open question) by flashing that
variant instead as a fifth attempt: **identical `+0xB3C` offset, identical
Download Mode result.** Ruled out. Confirmed `text_offset=0` in both
source and the linked binary's disassembly, so a compliant bootloader
should jump to offset 0 (`_head`) — the constant `0xB3C` regardless of
file content most likely reflects a fixed value in ABL's own debug
logging, not necessarily the real jump target.

Also got a genuine positive confirmation while checking this: all four
custom partitions (`boot`/`dtbo`/`vendor_boot`/`init_boot`) show
`AUTHENTICATE fail but allow` in every capture — the AVB bypass is fully
validated across the whole chain, not just `vbmeta`/`recovery`.

**Flagged an open methodological concern rather than continuing to guess
blindly**: every diagnosis so far has gone through a TWRP → crash →
Download Mode → user exits → TWRP round trip. Tried to test directly
whether Download Mode preserves the sec-log DRAM region (created
`/dev/mem`, tried `devmem` reads/writes) — blocked by `STRICT_DEVMEM`
policy, since `/proc/iomem` tags the region `System RAM` (rejected even as
root). **No way currently to confirm or rule out that Download Mode
clears this memory before we read it back** — if it does, every "zero
signal" conclusion so far could be an artifact of the diagnostic path,
not proof our code never executed. Reported this honestly to the user
rather than continuing to add more checkpoints on an unverified
assumption.

## Session 4 (2026-09-05, continued): the real root cause, mainline finally
boots, and a new post-boot mystery

**Dropped uniLoader** (plan revision, user-directed): packaged the raw
mainline kernel `Image` directly as `boot`'s kernel slot instead. Attempt 6
failed identically to all five uniLoader attempts — but this time the
*entire* `/proc/last_kmsg` capture was read line-by-line instead of grepped
for expected markers, and it found the real failure, present identically
in all six attempts: `"No Valid Dtb" / "Unable to find the Board Dtb" /
"Error: Board Dtbo blob not found"`, immediately followed by ABL launching
Odin — **before ABL ever touches the kernel payload slot**. Every earlier
"uniLoader crashed after Exit Boot Services" conclusion was a
misattribution: that content belonged to ABL's automatic fallback boot
into `recovery` after this exact error, not to the attempt being diagnosed.
This resolved the open "Download Mode might be clearing the diagnostic
region" concern from Session 3 as moot — the sec-log capture path was
working fine the whole time; the earlier sessions were just looking at the
wrong boot cycle's content within it.

Attempt 7 fixed a real bug in the DTBO builder (missing 8th header field,
misaligning every entry by 4 bytes) — insufficient: a *correctly-formed*
empty DT table is still a DT table, still triggers ABL's rejection path.

**The actual fix**, found by the user pointing at two locally-cloned
reference ports:
- `sm-x800-linux/` (postmarketOS, Tab S8+, SM8450 — older SoC generation):
  confirms ABL's DTBO-fragment-merge corrupts a mainline DTB, and
  documents uniLoader as the fix on *that* SoC.
- `ubuntu-galaxy-tab-s9ultra/` (SM-X910 Ultra — **same SM8550 chip
  generation as this device**): boots mainline directly, no uniLoader.
  Its `validate-bundle.sh` asserts, by name, that a `dtbo.img` whose first
  4 bytes parse as the DT table magic fails the build — exactly our error,
  named and guarded against on the one port that's proven this chip
  generation's ABL on real hardware. Its recipe: `dtbo.img` is a
  **4096-byte all-zero blob** (no DT-table magic at all, so ABL can't take
  the ufdt path and falls back to `vendor_boot`'s DTB, unmerged); `boot`'s
  kernel is **gzip'd with the board DTB concatenated directly after** the
  compressed stream (confirmed independently: ABL's own log unconditionally
  shows a `"Decompressing kernel image"` step); generic/vendor ramdisks are
  **legacy LZ4**, not gzip.

Adopted this recipe verbatim in `scripts/build-android-v4-bundle.sh`
(**attempt 8**) — **it worked**: no more Download Mode, zero occurrences of
`"No Valid Dtb"`, and genuine mainline kernel boot text in
`/proc/last_kmsg` for the first time: `Linux version 7.2.0-dirty`, all 8
CPUs at EL1, and — the first time this session's own from-scratch driver
ever produced output — `x716-sec-log log-buf: sec-log console registered`.
uniLoader is now confirmed **unnecessary** for this SoC generation and
dropped for good (files kept in-repo, unused).

Attempt 8 then hit a **silent hard reset** — no Oops/panic text, just a
cold PMIC reset — immediately after the last interconnect provider probe
(`7e40000.interconnect`). Matched a risk already flagged in this project's
own DTS comments: pinctrl-msm's TLMM probe touching a TrustZone-locked
GPIO is a documented SM8550-family crash cause, and this board had no
`gpio-reserved-ranges`. Attempt 9 (`&tlmm { status = "disabled"; }`,
blanket bisection) changed the symptom to a **silent hang** (black screen,
no auto-reset, needs a manual power cycle) — confirming *something* about
tlmm was the issue. Attempt 10 replaced the blanket disable with the real
fix: `gpio-reserved-ranges = <36 4>` (GPIOs 36-39, `qup1_se2`) — found by
checking `ubuntu-galaxy-tab-s9uwifi`'s own DTS (same reservation) and its
`porting-log.md`, which identifies that exact range as the fingerprint
sensor's SPI bus, confirmed TrustZone-owned on real X910 hardware; and
independently, X716's own stock decompiled DTS agrees on the same
`pm8550_gpios "gpio12"` pin for an unrelated purpose (SD card detect),
reinforcing that the two boards share PMIC/pin wiring closely enough for
this to be trustworthy. Same qualitative result as the blanket disable
(silent hang, no crash-loop) — while keeping tlmm/UART/UFS functional.

### The diagnostic channel hits a hard capacity wall

Getting a clean capture of what happens *after* the tlmm fix proved much
harder than expected. Root cause, confirmed by careful investigation (not
assumed): reaching TWRP at all — the only way to read `/proc/last_kmsg` —
requires a full boot cycle, and that cycle's own necessary XBL/PBL/ABL
preamble text is verbose enough (thousands of lines) to overwrite our own
kernel's comparatively tiny console output (at most a few hundred lines
before hanging) in the shared 2 MiB ring buffer almost every time. This
explains a sequence of confusing/contradictory-seeming captures:
byte-identical reads across separate real reboots (early on, before
understanding this), and consistently seeing what turned out to be
**TWRP's own kernel boot banner** (`Linux version 5.15.167-gae6e4eea
(edgars@arch)`, loading `hung_task_enh.ko` and dozens of stock Android
driver modules) rather than anything from our own kernel — a red herring
that took real effort to recognize as such. A tight `until adb get-state
...; done` polling loop (grab `last_kmsg` the instant `recovery` is
reachable, rather than waiting on manual confirmation) reduced but did not
eliminate this — even a *single* required transition to recovery is
often enough noise to erase everything.

One genuinely informative data point survived this problem despite the
noise: **a 3-minute stretch of silent black screen with zero auto-reboot**,
despite kernel-level hung-task detection being active (see below) with a
15-second timeout. This is inconsistent with a real D-state deadlock
(which should have triggered `panic()` well within 3 minutes) and
consistent with the kernel having reached the bring-up ramdisk's own
intentional infinite `sleep`-loop `/init` — a possible, unconfirmed,
genuinely exciting "reached userspace" result.

**Kernel-level lockup/hang detection added** (`kernel/config/config-x716.fragment`):
`CONFIG_SOFTLOCKUP_DETECTOR`, `CONFIG_HARDLOCKUP_DETECTOR`,
`CONFIG_DETECT_HUNG_TASK` (+`BOOTPARAM_*_PANIC`), so a genuine hang turns
into a bounded `panic()` + `panic=10` auto-reboot instead of requiring
manual intervention (which was itself contributing to buffer
contamination). Note: ABL injects its own `nowatchdog` into the cmdline
(confirmed from captures — printed as an "Unknown kernel command line
parameter" before this change, since the handler didn't exist yet), which
disables the *softlockup/hardlockup* subsystem specifically
(`watchdog_user_enabled = 0` in `kernel/watchdog.c`) — unavoidable, since
ABL appends this after anything we control. `hung_task` detection
(`kernel/hung_task.c`) is a **separate subsystem with no such cmdline
hook**, and calls `panic()` directly — the one still expected to be
reliable.

### Two more verification attempts, to sidestep the ring-buffer problem entirely

1. **`simple-framebuffer`**: added a `/chosen/framebuffer` node + matching
   `splash-region@b8000000` reserved-memory node (name matters — copied
   from `sm8550-samsung-q5q.dts`'s own comment: *"the bootloader will only
   keep display hardware enabled if this memory region is named exactly
   'splash_region'"*) plus `CONFIG_FB_SIMPLE=y`, to inherit ABL's
   already-running boot-splash scanout for a plain `fbcon` text console —
   no real panel driver needed. Address/format (`0xb8000000`, `a8r8g8b8`)
   copied from `q5q.dts`, **unverified for X716**; only the resolution
   (2560×1600) is independently measured (from this device's own repeated
   `GlibGetLCDResolution` ABL log lines). **Result: nothing rendered.**
2. **Persistent microSD logging**: added `&sdhc_2` (regulators
   `vreg_l9b_2p9`/`vreg_l8b_1p8`, `pm8550_gpios` card-detect pin 12, pinctrl
   `sdc2_default`/`sdc2_sleep` already in `sm8550.dtsi`) + `CONFIG_EXFAT_FS=y`,
   and updated the bring-up ramdisk's `/init` to mount the card and
   periodically dump `dmesg` to a file — a persistence mechanism immune to
   ring-buffer wraparound entirely, since it survives indefinitely on the
   card regardless of how many subsequent reboots happen. Card-detect GPIO
   independently cross-validated (X716's own stock DTS and the X910
   reference both use `pm8550_gpios` pin 12), but the regulator names are
   **unverified for X716**, copied from the X910 reference by analogy only.
   **Result: no file appeared on the card** (confirmed by mounting it
   directly via `adb shell` from TWRP and listing its contents — TWRP's own
   kernel *can* mount it fine as exfat, so the card and filesystem
   themselves aren't the problem).

Both verification attempts came back empty, on the same "black screen"
symptom as before. This is itself informative: if the kernel were reaching
anywhere near as far as attempt 8 did (past several interconnect probes),
`fbcon` should show *something*, independent of whether the ramdisk's own
`/init` ever runs. Zero output from either channel raises real concern that
one of the changes made *after* attempt 8 (the `gpio-reserved-ranges` fix,
lockup-detector config, or the new `&sdhc_2`/regulator additions) may have
introduced a **new, earlier** hang rather than progressing forward from
attempt 8's crash point. Not yet bisected — see the plan for the proposed
next step (temporarily revert `&sdhc_2` to isolate it as a variable, since
its regulator values are the least-verified addition of the three).

### Bisection result, and a fourth verification channel: the kernel is definitely alive

Attempt 16 reverted `&sdhc_2`/its regulators (keeping `gpio-reserved-ranges`,
lockup detection, and the framebuffer) and reproduced **the exact same**
black-screen symptom as attempt 14 — ruling out the SD-card work as a new
regression. Direct memory inspection of the framebuffer region via TWRP's
own `/dev/mem` was also tried (to check whether our kernel ever actually
wrote there) and hit the same `STRICT_DEVMEM` wall as the earlier sec-log
`/dev/mem` attempt (Session 3) — `/proc/iomem` tags `0xb8000000` as plain
`System RAM` in TWRP's own memory map, so this path is a dead end too.

**The decisive test (attempt 17)**: added a `gpio-leds` node with
`linux,default-trigger = "heartbeat"` on GPIO 18 — measured, not guessed,
from this device's own ABL log (`[VIB] gpio num: 18` / `vib_onoff: 1`).
`CONFIG_LEDS_GPIO`/`CONFIG_LEDS_TRIGGERS`/`CONFIG_LEDS_TRIGGER_HEARTBEAT`
were already `=y` in defconfig — no kernel config change needed, just the
DTS node. **The tablet physically vibrated in a heartbeat pattern.** This
is a purely kernel-side signal (the heartbeat trigger runs off a kernel
timer, independent of ever reaching userspace) but it's unambiguous and
requires no log capture at all: **the kernel is genuinely alive, with
working GPIO/pinctrl/regulators/timers, deep into boot** — not crashed,
not deadlocked. This single result is worth more than every ring-buffer
capture attempted so far combined, and directly resolves the concern
raised by the bisection above: nothing added since attempt 8 broke the
kernel; it's still running.

**Follow-up (attempt 18)**: tried a minimal USB gadget serial console
(`CONFIG_USB_G_SERIAL=y`, `&usb_1`/`&usb_1_hsphy` enabled, `dr_mode =
"peripheral"`) to get a live interactive shell over USB, deliberately
skipping the real Type-C signal path — X716's own ABL log references the
same `ps5169` redriver and `sm5714` MUIC chip names `ubuntu-galaxy-tab-s9ultra`
(X910 Ultra) uses for real, working USB, but wiring those up is a
significant addition (i2c drivers, port-endpoint graph, more regulators)
with its own real risk of a wrong guess, so the simpler "just try the bare
PHY" version was tried first. **No `/dev/ttyACM*`/`/dev/ttyUSB*` device
appeared on the host.** Consistent with the flagged risk: the external
redriver most likely does real, necessary Type-C lane-routing work, not
just signal conditioning — the DWC3 core can probably initialize
internally without it, but the signal likely never reaches the physical
connector. Not yet reverted (harmless to leave in place; doesn't explain
the black screen either way, since the heartbeat already proves the
kernel survives past this point regardless of whether USB enumerates).

**Where this leaves Phase 3**: the kernel is confirmed alive deep into
boot. What remains unconfirmed is specifically whether **userspace/PID 1**
(the bring-up ramdisk's `/init`) is ever reached — the heartbeat trigger
doesn't require this, and all three userspace-dependent verification
channels tried (SD-card write, USB shell, and indirectly the framebuffer
text which `/init` doesn't touch anyway) came back empty. The real Type-C
redriver/MUIC stack (`ps5169`/`sm5714`, matching X910's proven setup) is
the most promising next step for USB specifically, being the closest to a
already-proven-on-real-hardware recipe of the remaining options; the
SD-card regulator names are the next most likely wrong guess to revisit
otherwise, being copied from X910 without X716-specific confirmation
(unlike the card-detect GPIO, which is independently confirmed).

All raw captures for this session are under
`work/bringup-2026-09-05/last_kmsg-attempt{6,7,8,9,9b,9c,9d,9e,10,11,12,13,15,16,18,19}.txt`.

### Attempts 20-21: the full USB stack doesn't enumerate, and the real question gets asked

Attempt 20 built out the *full* USB Type-C stack matching X910's real, working
setup -- not just a bare PHY. Ported all three of X910's from-scratch GPL-2.0
drivers (`sm5714_battery.c`, `sm5714_usbpd.c` -- TCPM transport,
`ps5169.c` -- USB3/DP redriver) into the kernel tree (mainline already has
`phy-nxp-ptn3222.c` for the third chip, the eUSB2 repeater), plus the full
devicetree subtree: `sm5714_usbpd`'s USB-C connector node with real PDO
tables, the `ps5169`/`ptn3222` port-endpoint graph, `usb_dp_qmpphy` for the
SuperSpeed lanes, three new regulators (`vreg_l5b_3p104`, `vreg_l15b_1p8`,
`vreg_l3f_0p88`, the last needing a new `regulators-4`/die-"f" block and
`vreg_s4e_0p952`), and the i2c/i2c-hub buses each chip sits on. X716's own
stock DTS independently confirms the same three chips at the same i2c
addresses (`sm5714@49`, `usbpd-sm5714@33`, `ps5169@28`) as X910 -- real
evidence, though not proof the i2c *bus* numbers or regulator/GPIO wiring
also match. Two build fixes needed along the way: `sm5714_usbpd.c` used two
`struct tcpc_dev` fields (`adopt_retained_source_ufp`/
`consume_retained_sink_dfp`) that don't exist at this project's pinned
kernel tag (removed -- an X910-specific dock-reboot edge case, irrelevant
here regardless); `CONFIG_TYPEC_DP_ALTMODE` can only build in (`=y`) if
`CONFIG_DRM` is too (ours is `=m`), so DP altmode was dropped from both the
config and the DTS's connector node (orthogonal to the actual goal of a USB
data console); and `pm8550ve.dtsi` (needed, it seemed, for the die-"f"
regulator block) turned out to be unnecessary entirely -- X910's own DTS
doesn't include it either, since RPMh regulators are independent of the raw
SPMI PMIC node that file describes.

**Result: no `/dev/ttyACM*`/`/dev/ttyUSB*` device appeared on the host, and
zero USB activity in the host's own `dmesg` even after replugging and
rotating the cable** -- not just a failed enumeration, but no sign the
physical connection was ever negotiated at the electrical level at all.
Strongly suggests one of the three new i2c-based drivers failed to probe
(most likely an unverified regulator/GPIO/i2c-bus guess, the same failure
category as the microSD attempt), stalling the whole role-switch chain
before `dwc3` ever gets told to become a peripheral.

**The question that mattered more than the USB failure itself**: does the
GPIO-heartbeat vibration (attempt 17) actually prove the boot is healthy,
or could the kernel be permanently stuck in the deferred-probe/driver-
matching mechanism -- which doesn't panic or trigger `hung_task` (it's not
a bug, just the kernel retrying forever by design) -- meaning userspace
might *never* be reached regardless of how long the heartbeat keeps going?
This is a real, known failure mode for boards with new/incomplete
devicetrees, and this session had just added a lot of new, heavily
phandle-linked devicetree in one sitting (framebuffer, LEDs, and now a
dozen-plus USB nodes). Tested directly and cheaply: added
`fw_devlink=off deferred_probe_timeout=10` to the cmdline (attempt 20's
cmdline, no kernel rebuild needed) -- **zero change in observed behavior**,
ruling out fw_devlink-mediated deferred-probe deadlock as the explanation
(or at least, nothing was actually blocked by it).

**Attempt 21: definitive proof userspace is reached.** Rather than
continuing to guess, `scripts/build-bringup-ramdisk.sh`'s `/init` was
changed to repurpose the same GPIO-18 vibrator the kernel's own heartbeat
trigger uses, the instant userspace starts: turn off the `heartbeat`
LED trigger, do a burst of 5 fast one-second pulses (unmistakably
different from the kernel's own steady heartbeat pattern), then hand the
trigger back. **The distinct burst was felt.** This is unambiguous,
real-time, physical proof -- independent of any log capture -- that
`/init` genuinely runs. **Phase 3's exit criterion (kernel reaches late
boot / PID 1 handoff) is met.** The USB gadget's failure to enumerate is
now understood to be an isolated, independent problem with the new
Type-C devicetree's own wiring (almost certainly a wrong regulator/GPIO/
i2c-bus guess in the newly-added subtree), not a sign of a stuck or
half-booted system.

This is the single most important result of this entire session. Next
steps: either continue bisecting the USB Type-C stack now that it's known
to be a self-contained, non-boot-blocking problem (lower urgency, since a
working shell is convenient but no longer required to prove the port
works), or move to Phase 4 (a real Ubuntu rootfs, replacing the bring-up
ramdisk) now that the fundamental "does mainline Linux run on this
hardware" question has a confirmed, positive answer.

**What actually happened next (not narrated blow-by-blow in this file --
see the git commit history and README for the full arc)**: the USB
Type-C stack was in fact debugged to a genuine working state. Root causes
found, in order: `CONFIG_I2C_QCOM_GENI`/`CONFIG_PHY_SNPS_EUSB2`/
`CONFIG_PHY_QCOM_QMP_COMBO` all defaulting to `=m` in defconfig (useless
with no rootfs/modprobe at this bring-up stage -- the same bug class
found three separate times); the QUP wrapper parent nodes
(`qupv3_id_0`/`qupv3_id_1`/`i2c_master_hub_0`) defaulting to
`status = "disabled"` in `sm8550.dtsi`, silently no-op'ing every i2c child
node enabled under them; and finally `dwc3_get_dr_mode()`'s live
GHWPARAMS0 hardware readback permanently skipping role-switch device
registration when it resolves to peripheral-only, fixed by forcing
`dr_mode = "peripheral"` explicitly on `&usb_1` since the actual goal (a
USB2 gadget console) never needed dynamic role negotiation anyway. Result:
a genuine `g_serial`/CDC-ACM USB serial console
(`idVendor=0525, idProduct=a4a7`), reachable with `picocom -b 115200
/dev/ttyACM0` from any PC with just a USB-C cable -- no vibration codes
needed for anything past this point.

---

## Session 5 — 2026-09-05 — Display bring-up (DRM/panel) + a minimal Weston rootfs

Goal: drive the internal panel via mainline DRM/KMS + a real panel driver,
and bring up a very small Buildroot-built rootfs (Weston + weston-terminal)
to prove pixels actually reach it. Two Explore passes (display/DRM tracing;
build-script conventions) preceded any code changes -- see the approved
plan for the full reasoning; only the outcomes are logged here.

**Kconfig**: `CONFIG_DRM` had been disabled entirely
(`# CONFIG_DRM is not set`) as a side effect of the earlier
`CONFIG_PHY_QCOM_QMP_COMBO` fix (`depends on DRM || DRM=n`, and at the
time there was no display work in scope). Reversed: `DRM=y` satisfies that
exact same dependency just as well as `DRM=n` does --
`ubuntu-galaxy-tab-s9ultra`'s own fragment builds `DRM=y` alongside
`PHY_QCOM_QMP_COMBO=y` with no conflict (`config-gts9uwifi.fragment:4-6`).
Added `DRM_MSM=y`, `SM_DISPCC_8550=y`, `QCOM_LLCC=y`, `SM_GPUCC_8550=y`,
`BACKLIGHT_CLASS_DEVICE=y`, `DRM_FBDEV_EMULATION=y`,
`DRM_PANEL_SAMSUNG_ANA38407_X716=y`, plus `PM_DEBUG=y`/
`PM_ADVANCED_DEBUG=y`/`PM_TEST_SUSPEND=y` (needed for the cold-boot DDIC
recovery quirk below). Building this fragment for real (not just writing
it) surfaced one more instance of the exact same "consistent module
state" Kconfig bug class already found three times during USB bring-up:
`DRM_MSM` carries `depends on QCOM_AOSS_QMP || QCOM_AOSS_QMP=n`,
`QCOM_OCMEM || QCOM_OCMEM=n`, `QCOM_COMMAND_DB || QCOM_COMMAND_DB=n` in
addition to the `QCOM_LLCC` one we already had covered --
`QCOM_AOSS_QMP`/`QCOM_COMMAND_DB` already resolved to `=y` on their own
from other selectors, but `QCOM_OCMEM` defaulted to `=m` with nothing
else forcing it. Found via `merge_config.sh`'s own post-build MISMATCH
report (the same verification discipline `scripts/build-mainline-kernel.sh`
already had in place for the USB-era fixes), not guessed -- fixed by
adding `CONFIG_QCOM_OCMEM=y` explicitly.

**Devicetree**: mainline's `sm8550.dtsi` already ships complete
`mdss`/`mdss_dsi0`/`mdss_dsi0_phy`/`dispcc` nodes, `status = "disabled"`
by default -- nothing to add upstream, just enable + wire, mirroring
`ubuntu-galaxy-tab-s9ultra`'s own working display bring-up structurally.
Added:

- Three new panel-supply regulators on die "b" (`vreg_l12b_1p8`,
  `vreg_l11b_1p2`, `vreg_l13b_3p0` for vddio/vdd/vci) -- voltages measured
  from X716's own stock DTS `dsi_panel_pwr_supply` table
  (`gts9_eur_openx_w00_r00.dts:9205-9219`), LDO index letters/numbers
  copied from the X910 Ultra port by analogy (same die-assignment pattern
  the UFS/USB rails on this board already independently confirm, but not
  itself independently confirmed for the panel rails specifically).
- A `display_avdd` fixed regulator (GPIO load switch, ~5.5V AMOLED ELVDD)
  -- the single least-confident value in this whole session. X716's stock
  DTS names a `"display_panel_avdd"` regulator but its decompiled form
  lost the resolved GPIO (proxy-supply/phandle indirection that didn't
  survive decompilation, same class of gap as the UFS PHY rails from an
  earlier session). GPIO 187 is a first guess, reused from the stock
  tree's differently-named `panel_ldo_en` fixed regulator (the only
  concretely-GPIO'd, panel-adjacent enable line the decompiled tree
  actually resolves) -- re-verify this first if the panel never powers on.
- `sde_te` pinctrl state on gpio86 (TE line → MDP vsync input) -- measured
  independently two ways: X716's own stock DTS
  (`qcom,platform-te-gpio = 0x56 = 86`, `gts9_eur_openx_w00_r00.dts:8498`)
  and the X910 Ultra port using the exact same GPIO number for its own
  (different-part) ANA38407-family panel.
- `&dispcc`/`&mdss`/`&mdss_dsi0`/`&mdss_dsi0_out`/`&mdss_dsi0_phy` enabled,
  with a `panel@0` node: `compatible = "samsung,ana38407-amsa10fa01"`,
  `reset-gpios = <&tlmm 125 ...>` / `te-gpios = <&tlmm 86 ...>` (both
  cross-confirmed the same two ways as the TE pinctrl state above), 4 DSI
  data lanes.

**Panel driver** (`kernel/drivers/panel-samsung-ana38407-x716.c`, new
file): forked from `ubuntu-galaxy-tab-s9ultra/kernel/drivers/panel-samsung-ana38407.c`
(same ANA38407 DDIC family, different physical part AMSA46AS02) for
overall structure (regulator sequencing, prepare/enable/disable/unprepare
split matching this DDIC's own `samsung,delayed-display-on` property,
backlight device), but the actual DCS init/exit byte sequences are NOT
carried over from that file -- they were re-derived specifically for
AMSA10FA01 via a dedicated Explore pass through Samsung's own downstream
source:

- The real command source of truth turned out not to be plain C byte
  arrays (unlike what the reference driver's own upstream Samsung source
  used) -- `GTS9_ANA38407_AMSA10FA01_panel.c` only holds helper logic, and
  `GTS9_ANA38407_AMSA10FA01_PDF.h` is one opaque 459KB blob. The actual
  human-readable source is a sibling text file,
  `.../panel_data_file/GTS9_ANA38407_AMSA10FA01.dat` (1685 lines, a small
  Samsung-proprietary macro/conditional DSL) -- found and decoded by the
  investigating agent, not assumed to not exist after the first file came
  back opaque.
- Implemented the mass-production ("rev C-Z") init path only, not the
  separate rev-A-only path the `.dat` also defines (different sleep-out
  delay, an extra TSP_SYNC_ON macro) -- real hardware is unlikely to still
  be running pre-production silicon.
- This DDIC family's indirect-register-write convention turned out to
  differ between the two panels: AMSA10FA01 uses an Anapass-TCON-specific
  triple (`0xC1`=data, `0xB0 0x03`+`0xC0`=16-bit target address), not the
  Samsung-DDIC "gpara" convention (`0xB0`+`0xC1`) the reference
  AMSA46AS02 driver uses -- confirmed by X716's own DT flag
  `samsung,anapass-power-seq`, not assumed to be the same mechanism just
  because it's the same DDIC family.
- DSC config decoded byte-for-byte from the panel's own 88-byte PPS
  payload embedded in the `.dat`'s `DSC_SETTING` macro -- resolves to
  exactly the standard VESA/DSC 8bpp spec-default `rc_buf_thresh`/
  `rc_range_params` tables (not a custom tuning), and cross-checks exactly
  against the stock DTS's own DSC display-timing properties.
  Display-timing porch values (h/v front/back porch, pulse width) for
  both the 120Hz and 60Hz modes were read directly from the stock DTS's
  `qcom,mdss-dsi-display-timings` block (`wqxga120hs`/`wqxga60hs`) rather
  than invented.
- Brightness: DCS `0x51`, 11-bit (0-2047), confirmed via the downstream
  candela-map tables -- same bit width the reference AMSA46AS02 driver
  independently uses, now independently re-confirmed for this panel too
  rather than assumed transferable.
- **Deliberately not ported**: Samsung's optical-fingerprint HBM timing
  machinery. The stock DTS node does carry
  `samsung,support-optical-fingerprint` and the downstream common driver
  does have real vsync-relative HBM entry/exit timing code wired to it --
  which at first reading looks like this panel needs the reference
  driver's FOD sysfs/watchdog machinery too. But the Tab S9 series ships a
  side-mounted capacitive fingerprint sensor (a separate SPI device, see
  this board DTS's `gpio-reserved-ranges` comment), not an in-display
  optical one -- concluded this flag is inert boilerplate inherited from a
  phone panel definition with no HAL ever driving it, and left the FOD
  machinery out entirely (plain dimming path only). Flagged in the driver
  header as an assumption to revisit if real hardware behavior disagrees.
  Also not ported: an unconditional-for-rev-B-Z "HBM_FlatZ_SETTING"
  indirect register write inside the downstream brightness-dimming macro
  -- byte-identical to the reference driver's own FOD-enable write, which
  makes its real purpose on this panel genuinely unclear from the source
  alone; left out rather than guessed at.
- Cold-boot DDIC recovery quirk: carried over from the reference driver's
  own finding (this DDIC family answers a cold-boot ID readback with
  garbage, recovering only after one suspend/resume) as a working
  assumption for AMSA10FA01 too, not yet independently confirmed on this
  panel specifically.

**Ramdisk simplified** (`scripts/build-bringup-ramdisk.sh`): the entire
USB Type-C per-driver vibration-diagnostic marathon from the previous
session (i2c adapter counts, per-chip bound checks, typec port counts,
two multi-minute recheck passes) was removed -- it was attempt-specific
diagnostic code for a now-solved problem, adding several minutes of dead
time to every boot iteration, which directly worked against this
session's "fast-iterate on the debug ramdisk" plan. Kept: the 5-pulse
userspace-reached vibration burst (cheap, no host dependency) and the
`log()` helper, now defined *before* its first call site (an ordering bug
in the previous version silently swallowed several early log lines --
found while doing this cleanup, not previously noticed). Added: the
cold-boot suspend/resume trigger (`echo platform > /sys/power/pm_test;
echo mem > /sys/power/state`), guarded by an existence check so it's a
no-op rather than a failure on a kernel predating the Kconfig addition.

**Buildroot rootfs scaffolding** (`scripts/fetch-buildroot.sh`,
`scripts/build-buildroot-rootfs.sh`, `buildroot/configs/x716_defconfig`,
`buildroot/rootfs-overlay/`): a separate, smaller "prove the display
works" rootfs, explicitly not a replacement for the debootstrap-based
Phase 4 Ubuntu rootfs `shell.nix` already stages tooling for. Pinned
Buildroot `2026.08` (verified via `git ls-remote` against the actual
upstream repo, not guessed from memory -- pinned commit is the tag's
dereferenced target commit, `d5180309b1b66ef3b8eaccca70ad69be8e0729a1`,
not the annotated tag object itself). Ships as an initramfs
(`BR2_TARGET_ROOTFS_CPIO`+`_GZIP`), like the debug bring-up ramdisk --
nothing in this port's boot chain does a `switch_root` today, so that's
the natural fit; plugs into the existing `build-android-v4-bundle.sh` via
its already-supported `BRINGUP_RAMDISK` env var override, no changes
needed to that script at all.

Design decision: **no Mesa/GPU at all** for this milestone. Weston's DRM
backend falls back to its `pixman` (CPU) software renderer automatically
when no EGL/GBM/GLES packages are selected (confirmed by reading
`package/weston/weston.mk` directly: `-Drenderer-gl` is only set `true`
when all three of `BR2_PACKAGE_HAS_LIBEGL`/`_LIBGBM`/`_LIBGLES` are
present) -- no Buildroot toggle needed to force it, just don't select
Mesa. This sidesteps the session's single biggest potential rabbit hole
(Adreno GPU firmware loading/signing), which isn't needed just to prove
pixels reach the panel, and keeps the rootfs far smaller than the ~90MB
budget originally researched. `weston-terminal` also turned out not to be
a separate Buildroot package in this release at all -- it's one of
Weston's own bundled "tools" (`weston.mk` unconditionally passes
`-Dtools=...,terminal,...`), so plain `BR2_PACKAGE_WESTON=y` is
sufficient; no separate terminal package exists to select.

Validated by actually building the Buildroot config (not just writing
it): `make x716_defconfig && make olddefconfig` inside the fetched
`buildroot/upstream/` tree, then a symbol-by-symbol diff against the
committed defconfig (same discipline as the kernel fragment check).
First attempt was missing `BR2_TOOLCHAIN_BUILDROOT_CXX=y` -- weston
`depends on BR2_INSTALL_LIBSTDCPP`, a plain internal flag with no prompt
of its own, so its absence didn't produce any warning: `BR2_PACKAGE_WESTON`
was just silently missing from the resolved `.config` with zero
diagnostic output, and had to be traced by hand to
`package/gcc/Config.in.host`'s "Enable C++ support" option. After that
fix, confirmed clean: `BR2_PACKAGE_WESTON`/`_WESTON_DRM`/`_SEATD`/
`_EUDEV`/`_HAS_UDEV`/`_DEJAVU`/`_DEJAVU_MONO` all resolve `=y` with no
mismatches, and `BR2_PACKAGE_MESA3D`/`_HAS_LIBEGL`/`_HAS_LIBGBM`/
`_HAS_LIBGLES` are all absent (confirming the no-Mesa design actually
holds). A full package build was not run this session (long, and the
kernel/panel side needs real-hardware validation first per the approved
plan's staging) -- `buildroot/configs/x716_defconfig`'s Kconfig-level
resolution is confirmed correct, but no compiled Weston binary has been
produced or tested yet.

**Kernel build**: unlike the Buildroot side, the full kernel `Image` +
board DTB *was* built end-to-end this session (`scripts/build-mainline-kernel.sh`,
run twice -- the `QCOM_OCMEM` mismatch above was caught by the first run
and fixed before the second, which completed cleanly). This confirms the
DTS/Kconfig/panel-driver combination actually compiles against the pinned
v7.2 tree, which is a real signal (a DTS/Kconfig typo or a panel driver
API misuse would have failed here) but is not the same as confirming any
of it works on real hardware -- nothing in this session was flashed.

**Status at end of session (before flashing)**: kernel/DTS/panel-driver
changes build cleanly; Buildroot rootfs config resolves cleanly at the
Kconfig level; neither has been flashed or run on the physical tablet yet.

## Real-hardware validation, same session: it worked, first attempt

Flashed the kernel-only change (debug ramdisk, not Buildroot) per the
plan's staged order. **The panel lights up and shows real content**: the
generic Linux SMP boot logo (one Tux per CPU core — 8, matching this
SoC), a brief blank moment (the simplefb → real DPU/panel-driver
handoff), then a genuine fbcon text console with a blinking cursor,
alongside the still-working USB serial shell and GPIO heartbeat. This is
a first-attempt success on the single highest-risk, most-guesswork-laden
part of this session's work.

Confirmed via the USB serial shell's `dmesg` (zero errors/warnings/Oops
anywhere in the full boot log):

- `msm_dpu ae01000.display-controller: bound ae94000.dsi (ops dsi_ops)`,
  `dpu hardware revision:0x90000000`, `[drm] Initialized msm 1.13.0`,
  `[drm] fb0: msmdrmfb frame buffer device` — the full DPU/DSI/panel
  stack bound and initialized completely cleanly. ("no GPU device was
  found" is expected/harmless — no Adreno firmware, out of scope by
  design, doesn't block display.)
- `panel-samsung-ana38407-x716 ae94000.dsi.0: ana38407 panel id: 80 00 04`
  — the panel ID readback matches one of the two IDs the driver treats as
  valid, **exactly**. Two independent confirmations this is really this
  panel's genuine ID, not a coincidence: it read correctly (a) here, via
  our own from-scratch DCS read implementation, and (b) completely
  independently, ABL's own kernel cmdline for this exact boot carries
  `msm_drm.lcd_id=800004 sec_common_fn.lcd_id=800004` — Samsung's own
  stock firmware had already read the identical ID from this exact
  physical panel before Linux ever started.
- **The cold-boot DDIC recovery quirk (suspend/resume) turned out to be
  unnecessary for this panel**: the ID read back correctly on the very
  first attempt, at `[0.367966]`, before the ramdisk's suspend/resume
  trigger ever ran (`[10.642393]`) — unlike the X910 Ultra's DDIC, which
  needs that recovery cycle every cold boot. Either this specific
  DDIC/fab revision doesn't share that quirk, or ABL's own boot-splash
  handling of this panel happens to avoid triggering it. The quirk is
  kept in the ramdisk regardless (harmless — a second `80 00 04` readback
  after resume confirms no regression), as a safety net for revision
  variance across units rather than removed.
- This also means the AVDD regulator's guessed GPIO (187, this session's
  single least-confident value) was good enough for the panel to power on
  and respond correctly — no re-verification needed there for now.
- No errors anywhere in the fw_devlink-resolved OF graph cycle between
  `dsi@ae94000` and its `panel@0` child (the "Fixed dependency cycle(s)"
  lines are fw_devlink's normal, benign handling of that expected parent/
  child link, not a fault).

**Not yet flashed/tested**: the Buildroot Weston rootfs (still just
Kconfig-validated, no package build run) — now unblocked and the natural
next step, since the underlying DRM/panel pipeline this whole session
worried might not work is now confirmed genuinely alive.

## Buildroot rootfs: built, flashed, Weston confirmed on real hardware

The Buildroot build itself needed five more real fixes before it produced
anything, every one of them a Nix-hosting quirk rather than a config bug
(diagnosed by actually building it repeatedly, not guessed):

1. **`host-attr`'s configure failed the C-preprocessor sanity check** --
   plain `cpp` on PATH resolves to `llvm.clang-unwrapped`'s bare `cpp`
   (kept on PATH for Kbuild's own LLVM=1 discovery), which has no default
   header search paths on NixOS. Buildroot's top-level `Makefile`
   re-resolves `HOSTCPP` via `which cpp` unconditionally
   (`Makefile:311-332`), so exporting `CPP` doesn't help -- fixed by
   passing `HOSTCPP=<path to the properly-wrapped gcc's own cpp>`
   explicitly on the `make` command line in
   `scripts/build-buildroot-rootfs.sh`.
2. **`host-gcc-initial`'s own `libcpp` failed to compile**: nixpkgs'
   compiler wrapper enables a "format" hardening flag
   (`NIX_HARDENING_ENABLE`) that turns on `-Werror=format-security`, and
   GCC 15.3.0's own `libcpp/expr.cc`/`macro.cc` have several
   non-literal-format-string calls that are fine under upstream GCC's own
   bootstrap toolchain but become hard errors under that flag. Fixed by
   dropping just the "format" token from `NIX_HARDENING_ENABLE` for this
   script's own environment.
3. **`freetype` tried to compile a Windows resource file**: a real
   `windres` binary exists on PATH (`llvm-windres`, from the same
   Kbuild-needed package), fooling freetype's libtool-generated build
   into unconditionally attempting `ftver.rc` (a Windows-only version
   resource) via `builds/freetype.mk`'s `ifneq ($(RC),)` gate. `RC=:` (a
   shell no-op, first tried) was the wrong value -- it made that
   conditional see RC as "present" and still add `ftver.o` to the final
   link, just without anything actually producing that file, moving the
   failure to the link step instead. `RC=` (truly empty) is what actually
   disables it.
4. **`host-patchelf`'s own binary couldn't run at all** --
   `error while loading shared libraries: libstdc++.so.6: cannot open
   shared object file`, even inside nix-shell, since Buildroot resolves
   `HOSTLD` to the raw `llvm-binutils` `ld` directly (same class of issue
   as HOSTCPP above) rather than linking through the wrapped `c++`, which
   is what would normally auto-inject a working rpath on NixOS. Fixed by
   copying the exact `libstdc++.so.6` the wrapped `c++` resolves to
   (`c++ -print-file-name=libstdc++.so.6`) into Buildroot's own
   `host/lib/` -- already on every host tool's rpath (Buildroot's own
   per-package LDFLAGS explicitly add `-Wl,-rpath,$(HOST_DIR)/lib`), so no
   further build-system change was needed once the file was there.
5. Considered and explicitly rejected: switching the whole rootfs to
   prebuilt Alpine `.apk` packages instead of building from source, to
   sidestep all of the above. Checked against Alpine's real `v3.24`
   aarch64 APKINDEX first rather than assumed: Alpine's precompiled
   `weston` unconditionally links against Mesa (`libEGL.so.1`/
   `libGLESv2.so.2`/`libgbm.so.1`), whose own Alpine build requires
   `libLLVM.so.22.1` (`llvm22-libs`: 64 MiB compressed / 176 MiB
   installed, alone) plus GStreamer/PipeWire -- roughly 250MB+ installed,
   defeating the entire point of this rootfs (proving the display works
   without the Adreno GPU firmware/Mesa rabbit hole). Buildroot's own
   from-source build, with Mesa/EGL/GBM never selected at all, produced a
   complete `rootfs.cpio.gz` at **15,080,124 bytes (14.4 MiB compressed)**
   -- confirming the original no-Mesa design decision was right, worth the
   extra Nix-hosting friction to keep.

**A real, hard packaging limit found next**: pointing
`BRINGUP_RAMDISK` at this rootfs and building the bundle failed --
`avbtool`: "Image size of 17743872 exceeds maximum image size of
8318976 in order to fit in a partition size of 8388608" -- the LZ4-framed
rootfs (~17 MiB) is bigger than `init_boot`'s fixed 8 MiB partition,
unlike the tiny (854 KiB) debug ramdisk that always fit comfortably.
`vendor_boot`'s partition is 96 MiB (`vendor_boot_size=100663296`) and
currently carries a redundant copy of the same small ramdisk `init_boot`
does -- ABL combines both into one initramfs at boot (standard mainline
behavior: concatenated cpio archives, not an Android-specific trick), so
there's no reason the big rootfs can't simply live in `vendor_boot`'s slot
instead while `init_boot` carries something tiny. Fixed by splitting
`scripts/build-android-v4-bundle.sh`'s single `BRINGUP_RAMDISK` input into
two independent overrides (`INIT_BOOT_RAMDISK`, `VENDOR_RAMDISK`, both
still defaulting to the old shared `BRINGUP_RAMDISK` for existing
behavior) plus an explicit per-partition size check that fails fast with
a clear message instead of avbtool's less obvious one. `init_boot` was
given a genuinely empty cpio (zero files) rather than reusing the debug
ramdisk, specifically so there's nothing in it that could override a
same-named path from `vendor_boot`'s real rootfs regardless of which
archive ABL concatenates first.

**Flashed and confirmed working, same session.** Booted to the same
Tux-array/fbcon-cursor sequence as the kernel-only test, this time with a
real Buildroot userland underneath. Debugged live over the USB serial
shell (`picocom`, login `root` with an empty password) rather than
guessing:

- `/etc/init.d/S99weston` didn't come up on its own -- `ps aux` showed no
  weston/seatd process at all. Running it by hand surfaced two real,
  independent bugs:
  - `/usr/bin/seatd: not found` -- `BR2_PACKAGE_SEATD=y` (auto-selected by
    weston, confirmed present in the resolved Buildroot `.config`) doesn't
    actually put a `seatd` binary at that path on this rootfs. Turned out
    not to matter: weston's own log shows libseat's **builtin** backend
    working completely on its own as root ("Trying libseat launcher...
    Started embedded seatd ... libseat: session control granted") with no
    external seatd process at all -- the `seatd` start attempt is now
    guarded behind an existence check rather than fixed further.
  - `fatal: failed to create compositor backend`, preceded by
    `warning: no input devices found... failed to create input devices`.
    Real cause, not a bug: no touchscreen (explicit non-goal, see below)
    and no physical keyboard/mouse means libinput finds zero seats, and
    Weston's DRM backend treats that as fatal by default. This is
    Weston's own documented scenario (`doc/sphinx/toc/running-weston.rst`,
    confirmed by reading it in the actual fetched source, not guessed):
    `--continue-without-input` (or `weston.ini`'s `require-input=false`)
    is the real, intended flag for exactly this kiosk/no-input case.
  - `--tty=1` (kept from the original design) turned out to itself cause
    a *different* fatal error one step later ("unhandled option: --tty=1"
    at shell-module load, after DRM backend init had already fully
    succeeded) -- dropped; weston allocates a VT fine without it.
- Once both were fixed and weston launched by hand, its log confirmed the
  full pipeline working end to end: `using /dev/dri/card0`, `DRM: supports
  atomic modesetting`, `DRM: supports GBM modifiers`, `Using Pixman
  renderer`, `DRM: head 'DSI-1' found, connector 36 is connected`, and
  both display modes from the panel driver
  (`2560x1600@120.0, preferred` / `2560x1600@60.0`) recognized correctly.
  `weston-desktop-shell`/`weston-keyboard` launched, and **`weston-terminal`
  connected and rendered on the panel** -- confirmed directly by the user
  looking at the tablet, not just inferred from logs.
- One iteration snag, not a real bug: a stale `wayland-0` socket lock
  from an earlier failed attempt made a later successful weston instance
  bind `wayland-1` instead, so `weston-terminal` needed an explicit
  `WAYLAND_DISPLAY=wayland-1` to find it that one time -- irrelevant on a
  clean boot (no stale lock), not something the init script needs to
  handle.

`buildroot/rootfs-overlay/etc/init.d/S99weston` has been updated to match
everything found above (dropped `--tty`, added `--continue-without-input`,
guarded the `seatd` start) but **the fix hasn't been baked into a fresh
flashed image yet** -- tonight's on-device verification patched and
re-ran the script live over the serial shell instead of rebuilding.
Rebuilding the Buildroot rootfs once more (picking up this fix) and
reflashing is the next concrete step before trusting a cold boot to bring
Weston up unattended.

## Session 6 — 2026-09-06 — Touchscreen driver port, and a real-hardware regression saga

Display + Weston were proven working (Session 5). Next up per the user's
explicit direction: touchscreen, before Ubuntu.

### The driver port

An Explore pass initially trusted `docs/hardware-facts.md`'s claim that
mainline ships a usable `drivers/input/touchscreen/st/fts` driver, needing
only DTS wiring (like the sibling Ultra's Goodix touch). **That claim was
wrong** — confirmed and corrected: no such path exists in the pinned v7.2
tree. The only in-tree candidate, `stmfts.c` (`compatible = "st,stmfts"`),
targets a much older, protocol-incompatible ST "FingerTip" chip. The real
hardware is an ST **fts1ba90a** (I2C `0x49` on `qupv3_se4_i2c`/`&i2c4`, IRQ
gpio 25, no reset-gpio), for which Samsung ships a ~10k-line downstream
driver (`fts_ts.c`/`fts_sec.c`/`fts_fwu.c`) on their private `sec_input`
framework. User's call: port it into a new, minimal mainline-style driver
rather than defer.

Two follow-up Explore passes scoped exactly what's load-bearing (probe
sequence, opcodes, power-on ordering and delays, the in-band system-reset
command, event-FIFO framing and bit-packing, chip-ID validation) vs. safely
omittable (firmware flashing/`request_firmware()` — the downstream driver's
own logic shows the IC ships with valid resident firmware and "skip fw
update" is the normal outcome every boot; all of `fts_sec.c`'s
factory/sysfs/production-test code; TCLM calibration; gesture/AOD/sponge;
DeX mode; secure-touch). Resulted in
`kernel/drivers/touchscreen-fts1ba90a-x716.c` (~500 lines, house style
matching `ps5169.c`): mainline's own `touchscreen_parse_properties()` /
`input_mt_init_slots(..., INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED)` /
`input_mt_sync_frame()` idiom (same pattern the sibling Ultra's mainline
Goodix driver uses) replaces Samsung's hand-rolled `sec_input_set_prop()`
entirely — simpler and more idiomatic than a direct port.

**Firmware side-quest**: with the device in TWRP, `/vendor` (dm-5, ext4,
*not* erofs as the stock fstab's generic entry suggested) was mounted
read-only and `/vendor/firmware/tsp_stm/{fts1ba90a_gts8p.bin,
fts1ba90a_gts9.bin}` pulled via `adb pull` to `vendor-firmware-dump/`
(gitignored — proprietary). This board's measured `board-id 04` uses
`fts1ba90a_gts8p.bin` per the stock `_r04` DTS. Not wired into any build
step, though, since firmware flashing is deliberately out of scope for v1
(see above) — kept purely as a future option.

DTS wiring: a new `&i2c4` node (SE4, `qupv3_se4_i2c`; its `&gpi_dma1`
prerequisite was already satisfied by the earlier QUP-wrapper fix) with a
`touchscreen@49` child, plus a new `vreg_l14b_3p3: ldo14` regulator
(PM8550-b, 3.3V, for the touch AVDD rail — `tsp_avdd_ldo`/`pm_humu_l14` in
the stock DTS). Built cleanly (kernel + DTB compiled and decompiled
correctly, all phandles resolved) on the first attempt.

### It broke the device — twice, identically

First flash (debug ramdisk, same recipe that's been working since Session
5): **no display, no USB gadget console at all** — a regression from
already-proven-working functionality, not just "touch doesn't work yet."
Vibration heartbeat (the kernel's own lockup-safety LED trigger) still
pulsed, and TWRP still booted fine on top of it, ruling out a hard brick.

Restored to the exact known-good commit (`51912f9`, pre-touchscreen) via
`git stash push -u` + rebuild + reflash — fixed immediately, confirming the
regression really was caused by the new change and not something
environmental.

**Isolation test**: rebuilt with the driver + Kconfig symbol still compiled
in, but `&i2c4`'s `status` forced back to `"disabled"` — meaning the touch
chip's device node (and therefore the driver's own `probe()`) could never
be instantiated at all (`of_platform_populate()`/`fw_devlink` never even
walk a disabled node's children or phandle references, confirmed by reading
`drivers/base/core.c`/`drivers/of/property.c` directly). **Broke
identically anyway.** This ruled out the touchscreen chip's own on-bus
behavior and the driver's runtime I2C/IRQ logic as suspects — something
else in the change was at fault.

### Three static-analysis hypotheses, three misses

1. **Kconfig dependency-graph side effect?** Ruled out with hard evidence:
   built the known-good and isolation-test configs into two separate
   directories (first attempt used a relative `BUILD_OUT`, which `make -C
   $kdir O=$outdir` resolves against `$kdir`'s post-`-C` cwd rather than the
   invoking shell's — a latent footgun in any script using `BUILD_OUT` this
   way, worth remembering) and diffed the full, fully-resolved `.config`
   files line by line: **exactly one line differs**, the touchscreen symbol
   itself. Zero cascading changes to any unrelated symbol.
2. **Stale/wrong build artifact flashed?** Ruled out: rebuilt the exact same
   source state completely from scratch into a fresh output directory and
   compared — the DTB sha256 hash **matched byte-for-byte** what was
   actually flashed for the isolation test. (Image hash differs between
   any two builds regardless of source changes — expected, kernel builds
   embed non-deterministic build-id/timestamp data; raw Image *size* was
   identical, 44,423,680 bytes, across every build this session, touchscreen
   or not — an oddity probably explained by Image-format padding, not
   evidence of anything.)
3. **Incomplete flash / didn't sync before reboot?** The first break
   happened after an immediate self-triggered `adb reboot` with no explicit
   `sync`; both restores happened after asking the user to reboot manually
   (natural delay). Reflashed the *same already-hash-verified* isolation
   build with an explicit triple `sync` and a real 15s settle before
   rebooting. **Broke identically again.** Ruled out.
4. (A fourth, deeper hypothesis — the new `vreg_l14b_3p3` regulator node
   itself, unconditionally registered regardless of `&i2c4`'s status, being
   force-disabled by Linux's "disable unused regulators" `late_initcall`
   mechanism and cutting power to something shared with display/USB — was
   investigated via full source tracing of `drivers/regulator/core.c` and
   `drivers/regulator/qcom-rpmh-regulator.c`. Refuted with code-level
   certainty: in the isolation-test configuration, **no consumer ever calls
   `regulator_enable`/`disable`/`is_enabled` on this regulator at all**, so
   `_regulator_is_enabled(rdev) &lt;= 0` short-circuits `regulator_late_cleanup()`
   before it ever issues a real disable command — Linux never touches this
   rail's enable state either way in that configuration. Also cross-checked:
   the stock GTS9 tree, the sibling Ultra port, and this port's own DTS all
   independently agree PM8550-b LDO14 is touch-AVDD-only, no shared
   consumer anywhere.)

### The actual root cause: found via evidence, not more theory

Rather than a fourth hypothesis, captured the real kernel log from the
broken boot via `/proc/last_kmsg` (the same sec-log/TWRP-readback channel
proven in Session 4) — with a tight 1-second poll loop reading it the
instant TWRP reconnected, to beat TWRP's own boot log overwriting the 2 MiB
ring buffer (a documented capacity problem from Session 4). The capture
showed ABL genuinely loading our exact cmdline and kernel (`{ABL} Cmdline:
earlycon loglevel=8 log_buf_len=4M panic=10 ...`, byte-identical to
`scripts/build-android-v4-bundle.sh`'s cmdline) — and then **zero lines of
our kernel's own console output anywhere in the buffer**, before TWRP's own
stock 5.15.167 recovery kernel's boot banner appears. That's the signature
of a silent hard reset before the kernel could log anything — and this
project already root-caused this *exact* symptom once before, in Session 4
(a TrustZone-locked GPIO range causing an identical silent reset).

Checked `drivers/regulator/core.c`'s `machine_constraints_voltage()`
directly: `apply_uV` (set by `drivers/regulator/of_regulator.c` whenever
`regulator-min-microvolt == regulator-max-microvolt`, true for
`vreg_l14b_3p3`'s `3300000`/`3300000`) makes `set_machine_constraints()`
issue a voltage-set request on the regulator **unconditionally, at PMIC
regulator registration time** — independent of whether any consumer/driver
ever runs. The panel's `vreg_l12b_1p8`/`vreg_l11b_1p2`/`vreg_l13b_3p0` all
have the identical `min==max` pattern and are already proven safe on real
hardware, so this isn't a property of `apply_uV` in general — it points at
something specific to PM8550-b **LDO14** (possibly TrustZone-restricted,
unlike those three).

**Fix, confirmed on real hardware**: removed the `vreg_l14b_3p3` node
entirely (and the touchscreen's now-dangling `avdd-supply` reference),
keeping the driver, Kconfig symbol, and `touchscreen@49` DTS node (still
`status = "disabled"`) all in place. Rebuilt, reflashed — **display and USB
both came back immediately**, confirmed by the user. This is now the
checked-in state: touchscreen scaffolding (driver + DTS node) present but
disabled, pending either a correct non-TZ-restricted regulator index for
this rail or a different way to power it that doesn't route through a
plain devicetree regulator node — not yet resolved. Root cause is strongly
suspected, not 100% proven (haven't independently confirmed LDO14 is
actually TZ-restricted via any source outside inference from this
behavior), but the fix itself is confirmed and safe: three failed
hypotheses were each ruled out with hard evidence before landing on this
one, and removing the node measurably fixed the regression twice-reproduced
on real hardware.

---

## Session 7 — 2026-09-06 — Four-agent investigation finds the real root
cause: a wrong voltage, not TrustZone

Picked up Session 6's open problem (touchscreen disabled, LDO14 suspected
TZ-restricted) per the user's request to investigate a power fix properly
before instrumenting anything, by spawning four parallel research agents
against every available source *before* touching code: our own kernel
source tree, the sibling X910 Ultra port (`ubuntu-galaxy-tab-s9ultra/`,
present locally in this same repo tree), the downstream stock kernel
(`android_kernel_samsung_gts9/`, also local), and the public web. All four
converged on the same conclusion, which contradicts Session 6's leading
theory.

**Agent 1 (kernel-source tracing)** read `drivers/regulator/qcom-rpmh-
regulator.c`, `drivers/soc/qcom/cmd-db.c`, `drivers/regulator/of_regulator.c`
and `drivers/regulator/core.c` directly and found:
- A cmd-db lookup miss (a resource TrustZone/firmware never exposed to
  HLOS) fails gracefully: `cmd_db_read_addr()` returns 0, and
  `qcom-rpmh-regulator.c`'s own probe path checks for that and returns a
  clean `-ENODEV` with a `dev_err()` — never a crash, never malformed RPMH
  traffic. This actively refutes the "cmd-db miss/TZ-restricted resource
  crashes the SoC" mechanism Session 6 proposed by analogy to an earlier,
  unrelated reserved-GPIO-range incident.
- PM8550-b LDO14 maps to hw-type `pmic5_pldo` in
  `pm8550_vreg_data[]`, whose voltage ladder is
  `REGULATOR_LINEAR_RANGE(1504000, 0, 255, 8000)` — only
  `1504000 + N*8000` uV (N=0..255) is achievable. `3300000` (Session 6's
  value) is **not on this ladder**: `(3300000-1504000)/8000 = 224.5`,
  landing exactly between selector 224 (3296000) and 225 (3304000). Every
  one of the six *working* die-b siblings (`l17b`=2504000, `l5b`=3104000,
  `l13b`=3000000, `l15b`/`l12b`=1800000, `l11b`=1200000) lands on an exact
  selector.
- Because `regulator-min-microvolt == regulator-max-microvolt` sets
  `apply_uV` (`of_regulator.c`), this invalid value gets checked
  unconditionally at PMIC registration time in
  `machine_constraints_voltage()` (`core.c`): clamping to the achievable
  range gives `max_uV(3296000) < min_uV(3304000)`, and the function fails
  cleanly with `-EINVAL` — **before any RPMH command is ever built or sent**
  for this rail.
- `vreg_l14b_3p3` was the *last* child node in the `regulators-0` block.
  `rpmh_regulator_probe()`'s child loop aborts on first failure, and the
  resulting `devm_regulator_register()` failure triggers
  `device_unbind_cleanup()` → `devres_release_all()`, which unregisters
  **every already-registered sibling regulator from the same probe call**
  — including `vreg_l17b_2p5` (UFS vcc, already proven load-bearing). This
  plausibly explains why the *whole board* went dark rather than just touch
  failing to probe, without invoking TrustZone at all.
- Suggested fix: 3200000 uV (matching two other real boards it found, see
  below), optionally with `regulator-allow-set-load` +
  `regulator-allowed-modes` to match one of them exactly.

**Agent 2 (X910 Ultra port cross-check)** confirmed the sibling Ultra port's
own DTS (`ubuntu-galaxy-tab-s9ultra/kernel/dts/sm8550-samsung-
gts9uwifi.dts:575-580`) defines the *identical physical rail*
(PM8550-b LDO14, same `regulators-0`/`qcom,pmic-id="b"` block, same
`apply_uV`-triggering min==max pattern) as `vreg_l14b_3p2` — **3.2V**, not
3.3V — and wires it as `avdd-supply` for its own Goodix touch chip
(`touchscreen@5d`, `sm8550-samsung-gts9uwifi.dts:1550-1561`), which works on
real hardware. This directly refuted "LDO14 is universally TZ-locked on
this SoC generation": the same physical LDO, same DT idiom, works fine on a
sibling SM8550 device — just at a different (correct) voltage. (The agent
also noted the Ultra's DTS was imported wholesale from a mature upstream
postmarketOS project, so it's not evidence the Ultra team ever debugged
this exact issue themselves — but the *voltage value* itself is still
directly comparable and is the single clearest signal from this agent.)

**Agent 3 (downstream driver semantics)** traced `sec,regulator_boot_on` (a
property present on our own stock DTS's `touchscreen@49` node) through
`sec_common_fn.c` and confirmed it's parsed once and **never read again
anywhere in the touch driver** — dead/vestigial, unlike the analogous flag
in the S-Pen/Wacom driver (which only skips a 200ms delay). The downstream
driver's own `sec_input_power()` calls `regulator_enable()` on
`tsp_avdd_ldo` completely unconditionally, with no gate on this flag and no
`regulator_is_enabled()` check. Separately, this agent found **the
downstream reference tree's own `kalama-regulators.dtsi`** (Qualcomm's
generic SM8550 regulator definitions, which our board's stock DTS overlay
inherits *unmodified* — confirmed no `&L14B { ... }` override exists
anywhere in `gts9_eur_openx_w00_r04.dts` or its siblings) defines
`pm_humu_l14`/`L14B` at **`regulator-min/max-microvolt = <3200000>`** — i.e.
3.2V, matching the Ultra port and contradicting Session 6's "3.3V measured"
claim, which turns out to have been a misread: the stock DTS only ever
carries a *phandle fixup* for this rail (`L14B = ".../touchscreen@49:
tsp_avdd_ldo-supply:0"`), never a literal per-board voltage override, so
there was nothing to actually "measure" at 3.3V in the first place.

**Agent 4 (web research)** found the clinching piece of evidence: mainline
Linux itself already ships an accepted, real-Samsung-SM8550-device
devicetree — `arch/arm64/boot/dts/qcom/sm8550-samsung-q5q.dts` (Galaxy Z
Fold5) — which defines, in its own `regulators-0`/`qcom,pmic-id="b"` block:
```
vreg_l14b_3p2: ldo14 {
    regulator-name = "vreg_l14b_3p2";
    regulator-min-microvolt = <3200000>;
    regulator-max-microvolt = <3200000>;
    regulator-initial-mode = <RPMH_REGULATOR_MODE_HPM>;
};
```
— the exact same DT idiom (apply_uV-triggering equal min/max, PM8550-b
LDO14, **zero consumers** in that DTS) that crashed on our board, at 3.2V,
on a real, currently-maintained upstream Samsung SM8550 device. This agent
also found no public documentation anywhere naming any specific PM8550-b
LDO as TrustZone-restricted, and confirmed (independently reading the same
`cmd-db.c`/`qcom-rpmh-regulator.c` source as Agent 1) that a cmd-db miss or
unauthorized-resource case fails gracefully, not silently — further
evidence against the TZ theory. It also confirmed no mainline driver exists
anywhere for fts1ba90a (only downstream GPL sources), and surfaced a
directly relevant prior-art project, `aaronsb/sm-x800-linux` (a Galaxy Tab
S8+ mainline port, present locally in this environment at
`sm-x800-linux/`), which has *also* written a from-scratch `fts1ba90a`
driver from the same downstream source and reports it working — worth
comparing against in a future session if anything about our own driver
needs revisiting.

**Root cause (now confirmed, not just suspected)**: Session 6's
`vreg_l14b_3p3` used **3300000 uV, a value PM8550-b LDO14's hardware cannot
produce** (it falls between two real selectors on the LDO's 8mV-step
ladder). This is a plain DT-authoring error, not a TrustZone restriction —
that theory is now actively contradicted by three independent pieces of
evidence (the driver's own graceful cmd-db-miss handling, the Ultra
sibling's working use of the same rail, and mainline's own upstream Fold5
DTS using the same rail safely) and is retracted.

**Fix applied** (`kernel/dts/sm8550-samsung-x716b.dts`): re-added the LDO14
node as `vreg_l14b_3p2` at `3200000` uV (matching Qualcomm's reference
tree, the Ultra sibling, and `sm8550-samsung-q5q.dts`), re-enabled `&i2c4`
(`status = "okay"`), and restored the touchscreen node's `avdd-supply =
<&vreg_l14b_3p2>;`. Rebuilt cleanly (`out/kernel/arch/arm64/boot/dts/qcom/
sm8550-samsung-x716b.dtb`, no dtc warnings beyond this board's existing
harmless ones); decompiled the built DTB and confirmed the touchscreen's
`avdd-supply` phandle resolves to the new LDO14 node at `0x30d400` =
3200000 exactly.

**Confirmed on real hardware**: flashed and rebooted — display and USB both
still work (the regulator fix caused no regression), confirmed by the user.
This closed out the original crash. Touch itself, however, still didn't
come up — the investigation continued the same session.

**Bug #2, found via a live serial-console session (`/dev/ttyACM0`, this
board's USB serial gadget console — the fast iteration loop this whole
project has used since Phase 2)**: `dmesg` showed `&i2c4`'s controller
stuck forever in deferred probe: `a90000.i2c: deferred probe pending:
geni_i2c: Failed to get tx DMA ch`. Traced to `out/kernel/.config`:
mainline's defconfig ships `CONFIG_QCOM_GPI_DMA=m` (a module), and neither
this debug ramdisk nor the Buildroot/Weston rootfs ever loads kernel
modules — so `gpi_dma1`'s driver (`dma-controller@a00000`, the DMA engine
`&i2c4` needs for its tx channel, per `sm8550.dtsi`'s `dmas = <&gpi_dma1 0
4 QCOM_GPI_I2C>, ...`) never binds, and every QUP I2C/SPI bus depending on
it (not just i2c4 -- i2c6 too) is stuck the same way. **Fix**:
`CONFIG_QCOM_GPI_DMA=y` added to `kernel/config/config-x716.fragment`,
forcing it built-in. Rebuilt, reflashed — `dmesg` now showed the full
success sequence: `a00000.dma-controller` probes (`returned 0`),
`fts1ba90a 3-0049: resident firmware version 012400` (the chip responds
and reports its resident firmware, matching the "skip fw update" design
from earlier in this session), `input: fts1ba90a as .../i2c-3/3-0049/
input/input0` (a real evdev node created), and `/proc/interrupts` showing
the `fts_touch` IRQ (msmgpio 25) actively firing. **The touchscreen driver
and hardware both work end-to-end** — chip ID validated, firmware read,
input device registered, IRQ live.

**Bug #3, orientation**: with weston (`--continue-without-input` dropped
being unnecessary since libinput now found a real seat) running and touch
events flowing, the panel visibly showed touch input, but rotated/mirrored
relative to the actual finger position. Rather than guess-and-reflash,
captured raw `/dev/input/event0` bytes while tapping the on-screen
top-left and bottom-right corners in sequence: top-left produced raw
`(ABS_MT_POSITION_X, ABS_MT_POSITION_Y)` ~`(1535, 50)`, bottom-right ~`(55,
2505)`. The raw Y axis's ~2455-unit swing vs. raw X's ~1480-unit swing
(ratio ~1.66) matches the panel's own 2560x1600 aspect ratio (1.6) almost
exactly, confirming the sensor's native X/Y axes are transposed relative to
the panel's mounted orientation. Working through mainline's
`touchscreen_parse_properties()`/`touchscreen_apply_prop_to_x_y()`
(`drivers/input/touchscreen.c`) exact transform order (both `invert_x`/
`invert_y` apply to the *pre-swap* raw values, `swap_x_y` applies last)
against both measured corners algebraically (not by trial) gives one
unique combination that maps both correctly: `touchscreen-swapped-x-y` +
`touchscreen-inverted-x` (no Y invert). Rebuilt, reflashed — orientation
came out correct, confirmed by the user, but with a small, consistent
"touch registers down-and-left of the actual finger position" offset
(~3/4 cm).

**Bug #4, calibration offset**: rather than empirically fudge a
correction, spawned a research agent to extract the real geometry from
Samsung's own stock/downstream sources (per the user's explicit request —
"can you spawn another agent to extract the actual geometry from the stock
android os"). It found the actual bug: this port's
`touchscreen-size-x/y = <1752>/<2800>` values were copied from
`gts9_eur_openx_w00_r00.dts`'s `sec,max_coords` — the **r00 (pre-production)**
board revision, which was still wired to the Tab S8+'s "gts8p" touch
firmware/calibration (note the firmware filename), not this board's real
GTS9 configuration. From `r01` onward — including our actual board,
`r04` — Samsung's stock DTS uses `sec,max_coords = <0x640 0xa00>` =
`<1600 2560>`, which the agent independently cross-confirmed against the
ANA38407 panel's own native pixel resolution
(`qcom,mdss-dsi-panel-width/height` = 2560/1600 exactly) — zero border or
margin between raw touch units and panel pixels. It also confirmed (by
reading `sec_common_fn.c`'s `sec,max_coords` parsing and `fts_ts.c`'s
literal, untransformed coordinate unpacking directly) that Samsung's own
`sec,max_coords` is semantically identical to mainline's
`touchscreen-size-x/y`, and that neither the downstream driver nor any
stock config file applies a hidden offset/scale beyond that — so this
really was a plain wrong-board-revision copy error, fully discoverable
from stock sources, not something requiring empirical calibration. Fixed
`touchscreen-size-x/y` to `<1600>`/`<2560>`. Rebuilt, reflashed — **touch
now works correctly end-to-end**, confirmed by the user ("works
perfectly!").

**Summary of this session's three touchscreen bugs, each found and fixed
without trial-and-error flashing** (real hardware access was used only to
*confirm* fixes derived from source, never to search for one): a wrong
regulator voltage (not achievable on the LDO's hardware ladder), a module
vs. built-in Kconfig gap (`CONFIG_QCOM_GPI_DMA`) starving the touch I2C
bus's DMA channel forever, and a stale pre-production board revision's
coordinate range copied instead of this board's real one. All three were
root-caused by reading real source (kernel driver internals, sibling
ports, and Samsung's own stock devicetree) before writing any fix, per the
user's explicit direction this session to investigate thoroughly with
multiple parallel research agents before instrumenting anything.

## Session 8 — 2026-09-06 — Networking bring-up (WiFi + Bluetooth, QCA6490/WCN6855)

Greenfield WiFi/BT/PCIe work (Kconfig force, DTS `wcn_pmu`/`wifi@0`/BT-UART14
nodes, three out-of-tree kernel patches under `kernel/patches/`) got the
PCIe WLAN endpoint far enough to probe, but it still showed "Device not
found" after the first two patches (PHY pipe-mux unpark +
`pwrseq_qcom_wcn_program_wlan_pdc()` AOP votes). A round-3 research agent
recommended three further changes together: `xo-clk-gpios` GPIO
sequencing, reordering the AOP PDC vote before regulator/GPIO acquisition
plus switching `pwrseq_qca6390_of_data.targets` to
`pwrseq_qcom_wcn6855_targets`, and AON/PMU rail-mapping + voltage
corrections. Applying all three at once caused `wcn-pmu` itself to
regress from a clean probe to permanent `-EPROBE_DEFER` (`-517`).

Per the user's explicit standing instruction to prioritize concrete
source-of-truth evidence over speculation, this was root-caused by direct
kernel source reading plus real-hardware single-variable bisection, not
guesswork:

- **Read `drivers/base/dd.c`'s `really_probe()` directly**: a *negative*
  `-517` in a "probe of X returned N" `initcall_debug` line comes
  exclusively from `device_links_check_suppliers(dev)` rejecting the
  device *before* `.probe()` is ever called (a driver's own `.probe()`
  failure would instead show as a *positive* `517`). This is a pure
  devicetree-phandle-graph gate — it immediately exonerated the
  `.targets` swap and the PDC-vote reordering as possible causes, since
  neither touches the OF phandle graph.
- **Bisected on real hardware**, each on top of a reconfirmed-working
  "patches #1+#2 only" baseline, with temporary `dev_info(dev, "TRACE:
  ...")` probe-entry markers: the `xo-clk-gpios` property alone did not
  reproduce the regression when removed; the AON/PMU rail swap
  (`vddaon-supply`→`vreg_s2g_0p98`, `vddpmu-supply`→`vreg_s4e_0p952`)
  alone did not either (clean probe, all TRACE hits both times).
- **The actual cause**: the `vreg_s4g_1p352`/`vreg_s6g_1p904` regulator
  voltages had been "corrected" from `1352000`/`1904000` µV to
  `1350000`/`1900000` µV to match the PDC `upval` figures in mV exactly.
  Reading `drivers/regulator/qcom-rpmh-regulator.c`'s real voltage table
  for this board's actual PMIC (`pm8550vs`, confirmed via the DTS parent
  node) — `pmic5_ftsmps525`, two linear ranges: `300000-1368000µV` in
  `4000µV` steps, then `1376000-2736000µV` in `8000µV` steps — shows the
  *original* values are exact on-grid steps (`(1352000-300000)/4000=263`;
  `(1904000-1376000)/8000=66`), while both "corrected" values land
  exactly between valid steps (`262.5` and `65.5` respectively). With
  `regulator-min-microvolt == regulator-max-microvolt` set to an off-grid
  value, voltage-constraint application has no exact match and fails,
  which is exactly why the regulator (and therefore `wcn-pmu`'s supplier
  link to it) never became ready — mechanistically consistent with the
  `dd.c` proof above, not a coincidence. Reverted to the original,
  RPMH-valid `1352000`/`1904000`; confirmed live (`wcn-pmu` probe: one
  early defer, then all TRACE markers hit, `returned 0`).

With the root cause fixed, all three originally-recommended changes were
reintroduced together (patch `qca6490-xo-clk-gpio.patch` re-enabled,
`xo-clk-gpios` restored, TRACE debug lines removed) and flashed as one
full build. **Result, confirmed via real dmesg over the USB serial
console**:

- `wcn-pmu` probes clean (`returned 0`).
- The PCIe WLAN endpoint enumerates: `/sys/bus/pci/devices/` shows
  `0000:00:00.0` (root port) and `0000:01:00.0` (the chip) — the original
  "Device not found" is resolved. `ath11k_pci` binds and reads the real
  hardware identity via MHI SoC ID: **`wcn6855 hw2.1`** — not
  `QCA6390 hw2.0` as this device's own downstream DTS naming
  (`qcom,cnss-qca6490`) had implied. Firmware load then failed only
  because `ath11k/WCN6855/hw2.1/amss.bin` wasn't staged (fixed below).
- `hci_qca` fully talks to the real BT die over `&uart14`: `dmesg` shows a
  genuine version-command readback (`QCA SOC Version 0x400c0210`,
  `QCA ROM Version 0x00000201`, `QCA Patch Version 0x000038e6`) — real
  hardware, not a stub. It identifies as **`ROME/QCA6390`**
  (`soc_type QCA_QCA6390` in `drivers/bluetooth/btqca.c`), rom_ver
  **0x21**. Firmware download then failed on `qca/htbtfw21.tlv`
  (not staged — see below).

Note the WLAN and BT halves of this one physical chip identify as two
*different* things to their respective mainline subsystems, independently
and via two entirely separate real hardware-readback paths (MHI SoC ID
over PCIe vs. a live HCI vendor command over UART) — both real
measurements, not a contradiction.

**Firmware staging, `scripts/fetch-ath11k-firmware.sh` corrected**:

- WiFi: ath11k's own `hw_params` table sets `.fw.dir =
  "WCN6855/hw2.1"` for this exact `hw_rev` (confirmed in
  `drivers/net/wireless/ath/ath11k/core.c`). linux-firmware upstream only
  ships `ath11k/WCN6855/hw2.0/` (confirmed via its GitLab API tree
  listing — no `hw2.1` subtree exists there at all). Real-world
  precedent, not a guess: GitHub's `linux-surface/aarch64-firmware` repo
  (used for real ARM laptop bring-up) ships `ath11k/WCN6855/hw2.1` as a
  **symlink to `hw2.0`** — i.e. hw2.1 has no distinct firmware content,
  it just needs the hw2.0 blobs staged under the hw2.1 path the driver
  actually requests. The fetch script now does exactly that.
- BT: **known gap, not yet resolved**. `btqca.c`'s `QCA_QCA6390` case
  unconditionally requests `qca/htbtfw<rom_ver>.tlv` +
  `qca/htnv<rom_ver>.bin` with *no* fallback filename (unlike
  `QCA_WCN6750`/`QCA_WCN6855`, which retry a second name on failure).
  Confirmed by listing linux-firmware's own `qca/` directory: only
  `htbtfw20.tlv`/`htnv20.bin` (rom_ver 0x20) exist upstream — nothing for
  our hardware-confirmed rom_ver 0x21. This device's own pulled
  `vendor-firmware-dump` doesn't have an exact match either (it has
  `hpbtfw21.tlv`/`hpnv21*.bin` — same rom_ver, but the "hp" stem used by
  the `QCA_WCN6855`/`QCA_QCA2066` cases, a different fwname convention,
  not confirmed interchangeable). The real next step is extracting the
  genuine `htbtfw21.tlv`/`htnv21.bin` from this device's actual stock
  `/vendor/firmware` partition (today's `vendor-firmware-dump` pull may
  simply be incomplete), not substituting a same-rom_ver-but-wrong-prefix
  file and hoping it works. The fetch script now fails loudly and points
  at this exact gap rather than silently leaving BT firmware missing.

**Not yet done**: this networking test used the fast-iteration debug/
bring-up ramdisk (confirmed via live shell: no `/lib/firmware` directory
exists in it at all), not the full Buildroot rootfs with the firmware
overlay — so firmware loading itself, and any real WiFi/BT signal
(`iw dev wlan0 scan`, a BT scan/pairing), is still unverified. That's the
next real test once the Buildroot rootfs is rebuilt with this session's
firmware-overlay staging included.

### Full Weston+firmware rootfs test: WiFi confirmed end-to-end, BT has one remaining userspace gap

`scripts/extract-vendor-firmware.sh` (new, committable — pulls proprietary
blobs into gitignored `vendor-firmware-dump/` from this device's real
`/vendor` partition; TWRP doesn't always auto-mount it, so the script
mounts `/dev/block/dm-5` explicitly first) confirmed via a full,
exhaustive on-device search that no `htbtfw21.tlv`/`htnv21.bin` exists
anywhere real (upstream or on this device) — only `hpbtfw21.tlv`/
`hpnv21*.bin`/`hpnv21g*.bin` (rom_ver 0x21, "hp" stem). Reading
`drivers/bluetooth/hci_qca.c`'s real `qca_bluetooth_of_match[]` table
found the actual fix: our BT DTS node's `compatible` was
`"qcom,qca6390-bt"`, which maps to `soc_type QCA_QCA6390` — the one
`btqca.c` case with **no fallback filename** on failure. Switching it to
`"qcom,wcn6855-bt"` (matching the WLAN side's own real hardware identity)
makes `btqca.c` try `wcnhpbtfw21.tlv`/`wcnhpnv21.bin` first and fall back
to plain `hpbtfw21.tlv`/`hpnv21.bin` on failure — landing exactly on this
device's real files. Confirmed safe: `qca_serdev_probe()` only consults
`qca_soc_data_wcn6855`'s own regulator list when the BT node has an
`enable-gpios` property (ours doesn't — power is handled by the shared
`wcn_pmu` pwrseq device, matched via a regulator-supply phandle back to
that provider, unrelated to `soc_type`), so the switch is isolated to
firmware-naming logic only.

Also added `BR2_PACKAGE_IW`/`BR2_PACKAGE_BLUEZ5_UTILS`(+`_CLIENT`) to
`buildroot/configs/x716_defconfig` for real scan tools, and fixed a
second, unrelated bug the user caught by direct observation ("weston
didn't start as it couldn't mount the sdcard"): `INIT_BOOT_RAMDISK` had
been mistakenly pointed at the debug bring-up ramdisk instead of
`out/empty-ramdisk.cpio.gz` (the pattern Session 5 already established
and documented for exactly this reason) — the debug ramdisk's own `/init`
(which tries to mount the microSD for persistent logging, then loops
forever providing its own interactive shell) silently took over PID 1,
so Buildroot's real init/`S99weston` never ran at all. Not a boot hang or
an sdcard-driver bug; the sdcard mount failure inside that unrelated
ramdisk's `/init` was just the visible symptom. Fixed by using
`out/empty-ramdisk.cpio.gz` for `INIT_BOOT_RAMDISK` again.

**Confirmed on real hardware, full clean boot, Weston came up
automatically:**

- **WiFi — fully working.** `ip link` showed the interface renamed
  `wlan0` → `wlp1s0` by eudev's predictable-naming rules (real, not a
  bug). `iw dev wlp1s0 scan` returned **ten real, distinct SSIDs** from
  the surrounding environment (`Songo-5GHz`, `Songo-OpenWrt-2.4G`,
  `H155-383_3D90`, `TEACENTRE`, `eandC159D6-2G`, `AhmadQasim`,
  `Songo-5GHz-temp`, `Songo-2.4GHz`, `Be Different2`, `Ahmed`) — this is
  the real "AP seen in a scan" bar this project set for itself, met.
- **BT — firmware/kernel side fully working, BlueZ integration not yet
  resolved.** `dmesg` shows the same real chip handshake as before,
  ending in `QCA setup on UART is completed`; `/sys/class/bluetooth/hci0`
  exists; `/sys/class/rfkill/rfkill0` (`name=hci0`) shows `soft=0 hard=0`
  — not blocked. But `bluetoothctl` (via `dbus-daemon` and `bluetoothd`,
  both auto-started at boot, confirmed running) reports **"No default
  controller available"** even after a clean `/etc/init.d/S40bluetoothd
  restart` with `hci0` already fully up. Not yet root-caused — no
  speculation offered here; the real next step is checking whether
  `hci_register_dev()` completes with a quirk flag (e.g.
  `HCI_QUIRK_RAW_DEVICE`) that hides the device from BlueZ's mgmt
  interface, or a BlueZ-vs-kernel mgmt-API version mismatch, ideally via
  a focused subagent investigation rather than further guessing over the
  slow serial console.

### Real WiFi + SSH, replacing the serial console as the day-to-day channel

With real WiFi association already proven, the user asked to get off the
slow USB-serial console entirely via WiFi + SSH. Added to
`buildroot/configs/x716_defconfig`: `wpa_supplicant` (joins the real
network, credentials in the gitignored
`buildroot/rootfs-overlay/etc/wpa_supplicant.conf`) and `dropbear` (SSH2
server, static root password) driven by the new
`buildroot/rootfs-overlay/etc/init.d/S45wifi-connect` (waits for a real
wireless interface by checking `/sys/class/net/*/wireless` rather than
hardcoding `wlp1s0`, then `wpa_supplicant` + `udhcpc`).

**Two real bugs found and fixed, both root-caused from source, not
guessed:**

1. **`wpa_supplicant` rejected the whole config file** ("Failed to read
   or parse configuration") with zero per-line diagnostics. Read
   `wpa_supplicant/config_file.c`/`config.c` directly: its parser is
   all-or-nothing -- one unrecognized top-level directive silently
   increments an error counter (no message unless `show_details` is set)
   and the entire file is rejected at the end
   (`if (errors) config = NULL;`). The culprit was `ctrl_interface=`,
   guarded by `#ifdef CONFIG_CTRL_IFACE` (needs
   `BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE`/`_CLI`, not enabled). Fixed by
   removing it, then properly re-adding it once `BR2_PACKAGE_WPA_SUPPLICANT_CLI`
   was enabled for `wpa_cli` (which needs that same path).
2. **SSH connections timed out even after WiFi genuinely associated**
   (real IP, real ping RTTs, ARP resolves, dropbear confirmed listening
   on `0.0.0.0:22`/`:::22` via `netstat -tln`) -- ICMP fine, TCP silently
   dead, the classic symptom of a WiFi-driver checksum-offload bug.
   Diagnosed with on-device `tcpdump` (added specifically for this;
   host-side capture was blocked by missing `CAP_NET_RAW` in this
   sandbox) rather than guessing -- and on the very next boot, with
   `tcpdump` simply running as a passive observer, the same connection
   attempt succeeded outright. Inconclusive on the *original* root
   cause (a stale AP-side client/ARP table entry after re-association is
   the leading real-world explanation for "ICMP fine, TCP times out,
   then resolves on its own after a fresh association" -- consistent
   with power-save being toggled off on the affected boot too -- but
   this was **not** independently confirmed the way every other finding
   in this session was, and is flagged as such rather than asserted).
   SSH now works reliably; if it ever recurs, `tcpdump -i wlp1s0 -n port
   22` on-device is the direct diagnostic already proven to work.

Also added, per explicit request, a set of general debugging tools now
that a real network path exists: `ethtool` (the checksum-offload
diagnostic tool above), `netcat` (busybox's own `nc` applet is disabled
in this project's default busybox config; `netcat-openbsd` needs glibc,
incompatible with this musl toolchain), `tcpdump`, `pciutils` (`lspci`),
`usbutils` (`lsusb`), `htop`, `strace`.

**Confirmed working end-to-end via real SSH** (`sshpass ssh
root@192.168.2.123`, static root password): `uname -a`, `ps aux` showing
`wpa_supplicant`/`dropbear`/`weston` all healthy. The serial console
stays available as a fallback (kept running per the user's explicit
request), but is no longer the primary iteration channel.

### Bluetooth: BlueZ showed zero controllers despite real firmware loading; root-caused and fixed; real scan confirmed

With WiFi solid, the user asked to return to confirming Bluetooth works,
holding it to the same standard as WiFi: not "the driver probed" but a
real scan finding a real nearby device.

**Symptom**: `hci_qca`/`btqca` fully probed with the earlier
`"qcom,wcn6855-bt"` compatible fix (dmesg showed the fallback chain
working exactly as expected -- `wcnhpbtfw21.tlv`/`wcnhpnv21.bin` fail,
`hpbtfw21.tlv`/`hpnv21.bin` succeed, `QCA setup on UART is completed`) --
but `bluetoothctl show` reported "No default controller available", and
the kernel's own `mgmt` interface reported "Number of controllers: 0".
`hci0` existed and had loaded real firmware; BlueZ simply couldn't see
it.

**Root-caused by reading `net/bluetooth/hci_sync.c`, `hci_core.c`, and
`mgmt.c` directly**, not guessed:

- `hci_register_dev()` sets `HCI_SETUP`+`HCI_AUTO_OFF` and queues
  `hci_power_on()` automatically.
- `hci_power_on()` (`hci_sync.c`) sets `HCI_UNCONFIGURED` if
  `hci_test_quirk(hdev, HCI_QUIRK_EXTERNAL_CONFIG) || invalid_bdaddr`.
  `invalid_bdaddr` becomes true when no valid BD_ADDR is found anywhere
  -- and `hci_dev_get_bd_addr_from_property()` looks for a devicetree
  `local-bd-address` property, which our BT node didn't have at all.
- `mgmt.c`'s `read_index_list()` (~line 428) explicitly excludes any
  device with `HCI_SETUP`, `HCI_CONFIG`, `HCI_USER_CHANNEL`, or
  `HCI_UNCONFIGURED` from the controller list BlueZ enumerates -- which
  is exactly why `hci0` was invisible despite probing cleanly.

This is the same "factory NVM MAC address is null, needs an EFS-read
fixup" gotcha the sibling X910 Ultra port had already flagged as a known
risk for this chip family.

**Fix**: added a `local-bd-address = [1A 2B 3C 4D 5E 02];` property to
the BT node in `kernel/dts/sm8550-samsung-x716b.dts`. This is a
locally-administered placeholder (not the device's real factory
address, which lives in Samsung's own EFS partition and hasn't been
extracted) -- `hci_sync.c` reads the array LSB-first into `bdaddr_t.b[6]`
and displays it as `b[5]:b[4]:...:b[0]`, so `[1A 2B 3C 4D 5E 02]` shows
as `02:5E:4D:3C:2B:1A`; the `0x02` leading octet sets the standard
locally-administered bit, avoiding any real vendor OUI collision (same
convention as the `brcm,bcm4377-bluetooth.yaml` binding's own example).

**Confirmed fixed**: `bluetoothctl show` now reports `Controller
02:5E:4D:3C:2B:1A ... Powered: yes` -- BlueZ sees the adapter.

**Real scan, over the serial console** (SSH was down at the time due to
a transient WiFi re-association issue, unrelated to BT): one-shot
`bluetoothctl` invocations (`--timeout N scan on`, and
`echo "scan on" | bluetoothctl &`) all appeared to stop discovering
almost immediately -- their piped/redirected stdin hit EOF and the
process exited (confirmed via an immediate `[1]+ Done` job message and a
follow-up `Discovering: no`), never giving discovery a real window. Fixed
by keeping a `bluetoothctl` process's stdin genuinely open via a FIFO
(`mkfifo /tmp/btfifo; bluetoothctl < /tmp/btfifo > /tmp/scanresult.log
2>&1 &`, then `echo "scan on" > /tmp/btfifo`), which sustains BlueZ's
discovery session (tied to the requesting D-Bus client's connection
lifetime) for as long as needed. This found three real, distinct nearby
devices with real RSSI values:

```
Device 00:17:C6:D1:6F:D6 00-17-C6-D1-6F-D6
Device 02:F6:1A:99:6A:FE 02-F6-1A-99-6A-FE
Device 3F:13:A0:E2:B5:ED XDT_SQ669       RSSI -113 / -94 dBm
```

This satisfies this project's own standard of real signal, not just
probe success, for both radios now. Bluetooth is considered working for
bring-up purposes; the real factory BD_ADDR extraction (EFS) remains
deferred, noted in the DTS comment, until persistent BT identity across
reflashes actually matters.
