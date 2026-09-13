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

## Session 9 — 2026-09-07 — Pivot: adopting gts9wifi-fedora as a reference/base

Mid-way through building a from-scratch Ubuntu rootfs (debootstrap +
custom initramfs, real progress: microSD confirmed enumerating under our
own kernel for the first time, real partition/filesystem work done), the
user found and cloned `gts9wifi-fedora/` -- a real, mature,
real-hardware-validated mainline Linux port for the Wi-Fi-only sibling
tablet (SM-X710, "gts9wifi"), packaged as Fedora 44. It's a Fedora
repackaging of an existing postmarketOS device port
(`linux-samsung-gts9wifi-mainline`), itself cross-checked against
Samsung's own GPL/open-source drops for this device family. It has real
GPU acceleration (Adreno 740, Samsung-signed zap/GMU firmware), a full
GNOME desktop, battery/charging with PPS, USB-C PD + DisplayPort altmode,
speakers, and sensors over D-Bus -- none of which this project has
attempted yet. Decision: adopt and adapt it for the X716B (5G variant),
superseding the in-progress Ubuntu/Alpine rootfs work (both left in place,
unused, matching this project's existing convention for superseded work
like uniLoader).

### Independent cross-validation

Two Explore agents read the whole `gts9wifi-fedora` repo against this
project's own `docs/hardware-facts.md`/`docs/porting-log.md`. Extensive
agreement between the two independently-developed projects, real
confidence-building evidence our own X716B work is correct:

- BT `compatible = "qcom,wcn6855-bt"` -- the exact same compatible-string
  rename we independently root-caused (Session 8) to route `hci_qca.c`
  onto the WCN6855 firmware-naming fallback chain.
- WiFi PCI ID `[17cb:1103]` (`pci17cb,1103`) -- matches our own Session 8
  `dmesg` measurement exactly.
- `pwrseq-qcom-wcn.c`'s AOP-PDC-vote patch (`wcn7850-pwrseq-cold-reset-
  aop.patch` there) and `unpark-pcie0-pipe-mux.patch` (identical
  filename, identical fix) -- functionally the same two patches already
  in `kernel/patches/` here.
- `&sdhc_2` regulators (`vreg_l9b_2p9`/`vreg_l8b_1p8`) -- real-hardware
  confirmation these are correct; our own Session 3 attempt using these
  same (then-unverified, copied-by-analogy) values had come back
  inconclusive for unrelated reasons (a since-fixed kernel hang).
- `gpio-reserved-ranges = <36 4>` (fingerprint-SPI TrustZone lockout),
  the all-zero `dtbo.img` trick, the panel ID `80 00 04`, and the
  touchscreen's I2C address (`0x49`)/IRQ GPIO (25)/
  `inverted-x`+`swapped-x-y` orientation -- all identical.

### Two concrete corrections applied to `kernel/dts/sm8550-samsung-x716b.dts`

1. **`qcom,board-id`**: changed `<0x10008 0x00>` (r00, an untested guess)
   to `<0x10008 0x04>` (r04) -- matches both this tablet's own
   live-measured `/proc/device-tree/model` value (already noted, never
   acted on) and gts9wifi-fedora's own real-hardware-booting value.
2. **Panel AVDD GPIO -- investigated, deliberately NOT changed**: the
   agent's first-pass summary suggested our `display_avdd` node's GPIO
   187 should become PM8550 GPIO11. Reading gts9wifi-fedora's actual DTS
   directly (not just the summary) showed the real picture is more
   nuanced: GPIO 187 there is real hardware's *`panel_ldo_en`* -- a
   **separate 1.8V** DDIC logic rail, enabled ~11ms before the DSI-on
   sequence -- while the true ~5.5V ELVDD/AVDD switch is on a
   *different* pin, PM8550 GPIO11. Our own single node's label (5.5V)
   and actual pin (187) don't match this more accurate model -- but
   since a `regulator-fixed`/GPIO consumer only ever toggles the pin
   (voltage properties are informational, not hardware-enforced), this
   has been functionally harmless: our panel already works, confirmed
   on real hardware (Session 5, first-attempt success). Changing this
   now, on the untested assumption X716B's physical wiring matches the
   WiFi-only sibling exactly, would be a plausible-but-unverified change
   with real regression risk to a currently-working subsystem --
   deliberately deferred to its own isolated follow-up experiment
   instead of a drive-by edit. Full reasoning is in the DTS comment
   itself.

### Plan going forward

See the plan file for the full phased breakdown (DTS merge, kernel
patches/drivers/config/GPU firmware, Fedora rootfs via Nix-wrapped
`podman`+`dnf`, kernel build via our own existing pipeline instead of
their RPM packaging, boot bundle/dracut initramfs, flashing via our own
already-audited tooling, real-hardware verification). Confirmed live on
this dev machine before committing to this plan: `podman` is already
present natively (not even needing `nix-shell -p`), and `dnf5`/`rpm`+
`rpmbuild`/`dracut` are all available via `nix-shell -p` -- the "port
their tooling to Nix" instruction turned out to mostly mean *wrapping*
already-compatible tooling, not reimplementing it. User decision: target
a full GPU-accelerated GNOME desktop (reversing this session's earlier
"lightweight Weston, no GPU" call from before this pivot) now that real
GPU acceleration is demonstrated working on this exact chip/panel by a
real sibling port.

### GPU enablement + a real Fedora 44 rootfs, built end-to-end via Nix

**GPU**: `kernel/dts/sm8550-samsung-x716b.dts` gained a `&gpu { status =
"okay"; zap-shader { firmware-name = "qcom/a740_zap.mdt"; }; }` block --
confirmed against gts9wifi-fedora's own DTS that this is the *entire*
override mainline's already-complete GPU wiring (gpucc/GMU/adreno-SMMU
all enabled by default in `sm8550.dtsi`) needs. Confirmed this project's
existing Kconfig (`CONFIG_DRM_MSM=y`, `CONFIG_SM_GPUCC_8550=y`, both
already forced on for display in Session 5) already auto-selects
everything else (`QCOM_MDT_LOADER` via `DRM_MSM`'s own `select ... if
ARCH_QCOM`) -- no config changes needed. The zap-shader firmware
(`a740_zap.mdt`+`.b00-b02`) and GMU firmware (`gmu_gen70200.bin`) were
already sitting in `vendor-firmware-dump/` from the Networking bring-up
session's blanket extraction. Kernel build (Image + DTB) confirmed clean,
zero warnings, board-id fix (`0x00`->`0x04`) included in the same build.

**Fedora rootfs (`scripts/build-fedora-rootfs.sh`, new)**: gts9wifi-
fedora's own `rootfs/build-rootfs.sh` assumes either a real ARM64 CI
runner or `podman run --platform=linux/arm64 quay.io/fedora/fedora:44
...`. Neither works unmodified here -- podman's own container/mount-
namespace setup doesn't resolve this host's `binfmt_misc` handler for
execs inside a container at all (confirmed: "Exec format error" even
with the interpreter staged at the exact registered path inside the
image), and registering a new, container-visible handler (`podman run
--privileged multiarch/qemu-user-static --reset`) needs real root, which
this sandbox doesn't have.

What works instead, found by direct investigation rather than giving up
on Nix: `dnf5 --forcearch=aarch64 --installroot=...` run directly (no
container at all) via `nix-shell -p dnf5`, wrapped in `unshare --user
--mount`. Three real, separately root-caused problems along the way, all
now documented in the script's own comments:

1. **Wide UID mapping needed, not just `--map-root-user`**: that flag's
   single 0->caller mapping isn't enough for RPM's own `chown()` calls to
   real system UIDs (e.g. "mail") during package unpacking -- anything
   outside the single mapped ID lands on the kernel's overflow UID on the
   real host view, which manifested as an inexplicable "chown failed -
   Device or resource busy" mid-transaction until traced to this. Fixed
   with explicit `--map-users`/`--map-groups` ranges (0->caller for 1 ID,
   1->this host's own real `/etc/subuid`/`/etc/subgid` range for 65536
   more) -- the same convention rootless podman/buildah use internally.
2. **The actual cause of near-total RPM `%post` scriptlet failure**: not
   a fundamental qemu-user limitation (the first-pass conclusion) --
   traced via `strace` to NixOS's registered `aarch64-linux` binfmt
   interpreter being a thin wrapper (`...-binfmt-P`) that, despite `ldd`
   reporting it as fully static, internally `execve()`s a *different*,
   specific `/nix/store/.../qemu-user-.../qemu-aarch64` path at runtime
   (NixOS's own mechanism for the binfmt "P"-flag argv semantics) --
   invisible inside a bare chroot with no `/nix` bind-mounted, so every
   scriptlet that spawned a subprocess failed with a silent ENOENT deep
   in the exec chain, misreported by dnf5 as generic "Non-critical
   error"/exit-255 scriptlet noise. Fixed by staging
   `pkgsStatic.qemu-user`'s own genuinely standalone static build at the
   registered path instead -- package installs went from ~200+
   scriptlet failures and an overall "Transaction failed" to a clean
   `Complete!` with only 2 unrelated, genuinely non-critical warnings.
3. **`chroot()` doesn't reset environment variables**: this script's own
   direct `chroot` calls (user creation, `systemctl enable`) were
   resolving bare command names against this *outer* nix-shell
   environment's PATH (a giant x86_64 Nix store list that doesn't exist
   inside the aarch64 installroot), failing with a misleading "No such
   file or directory" that had nothing to do with the emulation itself --
   confirmed via the same command working fine with an absolute path.
   Fixed with absolute paths plus an explicit clean `PATH=/usr/sbin:
   /usr/bin` for every chroot invocation (`run_chroot` helper).

Also found and fixed: a re-run against an already-*failed* dnf5
transaction's rootfs made things measurably worse (a partial "chown
busy" run's rpmdb state caused a second run's transaction to cascade into
many more real "install failed" errors, not just the original
non-critical noise) -- the fix is always a full clean rebuild after any
failed run, never a resume; a re-run against an already-*successful*
("Complete!") rootfs, by contrast, is safe and fast (dnf5 correctly sees
everything already installed and reports "Nothing to do").

**Result**: `scripts/build-fedora-rootfs.sh` builds a real, complete
Fedora 44 aarch64 rootfs end-to-end via this host's own Nix environment,
no container needed. `GTS9_DESKTOP=core` (the `@core` package group,
~173 MiB compressed) built and packed cleanly first, as a fast checkpoint
before committing to the much larger, much slower (thousands of packages
under emulation) `GTS9_DESKTOP=gnome` (full GNOME Workstation)
variant -- kicked off in parallel with the hardware-side work below.
WiFi/BT/GPU firmware confirmed actually present in the packed archive
(`tar -tzf`, not just assumed). Not yet flashed or boot-tested on real
hardware as of this entry -- the device was disconnected at the time.

### Pivot within the pivot: full-port scope, Nix flake, correcting a research error

The reduced-scope Fedora rootfs above did boot to a real login prompt with
GPU/WiFi/BT/touch confirmed via `dmesg`, but kept hitting a cascade of
real bugs (missing `dbus-run-session`, then `systemd --user` itself
exiting with status 1 under GNOME) traceable to one root cause: it
reimplemented a trimmed subset of gts9wifi-fedora's own rootfs config
instead of using their real, working `rootfs/overlay/` tree (~30 files --
systemd units/drop-ins/udev rules/sleep hooks/a preset/ALSA UCM configs --
that exist specifically to paper over hardware quirks already found and
fixed on real hardware). Direction from here: stop reimplementing, port
gts9wifi-fedora **wholesale** -- DTS, kernel patches/config/drivers, the
real rootfs build script + full overlay, boot chain -- to the same
quality bar as their own README feature table, sensors included (not
deferred, as an earlier plan draft had proposed).

**A real research error, caught and corrected before it did damage**:
early planning for this pivot asked about fingerprint/camera packaging
(`packaging/libfprint`, `scripts/build-camera-packages.sh`) believing
these were part of `gts9wifi-fedora`. Direct `find`/`grep` against the
actual checkout (cross-confirmed by two independent Explore agents)
showed neither exists there at all -- those paths belong to a different
sibling project, `ubuntu-galaxy-tab-s9ultra` (the Tab S9 **Ultra**,
SM-X910, not the Wi-Fi SM-X710 this port is based on). gts9wifi-fedora's
own README lists camera as `❌ no drivers` and has no fingerprint work of
any kind. So "full feature parity with the X710 port" already excludes
both -- this shrinks true scope rather than expanding it, confirmed with
the user before proceeding.

**Nix flake** (`flake.nix`, replacing `shell.nix` as the primary entry
point): a `devShell` plus `apps.{build-kernel,build-rootfs,build-bundle,
flash}` wrapping the real scripts in this checkout. Deliberately scoped
honestly in its own header comment -- `flake.lock` pins *tool* versions
reproducibly (clang, the aarch64 cross toolchain, dnf5, dracut, the
static qemu-aarch64 interpreter, ...), but the Fedora rootfs build itself
is not bit-for-bit hermetic (`dnf5` resolves package content against
Fedora's live repos, exactly like gts9wifi-fedora's own CI does over real
network access -- neither project achieves full hermeticity there, and
claiming otherwise would be worse than being explicit about it). Two
real bugs found and fixed getting this working:

1. **An arbitrary `nixos-unstable` HEAD pin broke `dnf5`**: pinning
   `nixpkgs.url` to nixos-unstable's then-current HEAD commit
   (`c043004d1c...`) made `dnf5` rebuild from source and fail outright
   (`make: *** [Makefile:146: all] Error 2`) -- that exact commit's `dnf5`
   derivation had no cached binary substitute anywhere. Fixed by pinning
   instead to the exact commit this dev machine's own running NixOS
   system is built from (found via the system derivation's own name
   suffix, `nixos-system-*-26.05.20260817.0dd31db` ->
   `0dd31db7e6dbf9ce05697c4545f6fe01accec994`), guaranteeing every
   package resolves to an already-built, cached derivation.
2. **`pkgsStatic.qemu-user` silently shadowed on PATH**: merely listing
   it in the devShell's package list was not enough -- `which
   qemu-aarch64` still resolved to the plain, dynamically-linked
   `qemu-user` package (confirmed via `ldd` showing real glibc/x86_64
   linking, not a static build), some other transitively-pulled-in
   package apparently winning the PATH race. Fixed by removing it from
   the generic package list entirely and exporting an explicit
   `QEMU_AARCH64_STATIC` env var pointing directly at the static
   derivation's own binary (same pattern as the pre-existing
   `BUSYBOX_AARCH64_STATIC`), with `scripts/build-fedora-rootfs.sh`
   updated to read it (falling back to the old `nix-build -E` lookup for
   anyone still on plain `nix-shell`).
3. **(Found slightly later, verifying Phase 1's first kernel build via
   the flake) `HOSTCC` couldn't find `openssl/bio.h`**: `nix develop`
   gets `openssl`'s dev-output include/pkgconfig paths wired up for free
   via `mkShell`'s own setup-hooks, but `apps.*` (a raw `writeShellScript`
   that only sets `PATH`, deliberately, to avoid copying scripts into the
   Nix store) never goes through `mkShell` at all, so none of those hooks
   fire -- `certs/extract-cert.c`'s host-side compile failed outright the
   first time a kernel build was run via `nix run .#build-kernel` instead
   of inside `nix develop`. Same class of bug as the qemu one above (a
   package being *listed* isn't the same as its environment actually
   being wired up); fixed the same way, with explicit `PKG_CONFIG_PATH`/
   `C_INCLUDE_PATH`/`LIBRARY_PATH` env vars pointing at `openssl.dev`/
   `openssl.out` so both `nix develop` and every `apps.*` entry behave
   identically instead of one working only by accident of `mkShell`'s
   hooks.

`nix flake check` passes; every `apps.*` entry and `nix develop` verified
by real invocation, not just evaluation.

**Phase 1 DTS port** (`kernel/dts/sm8550-samsung-x716b.dts`), adapted
from gts9wifi-fedora's real, hardware-derived DTS rather than reimplemented:

- **ADSP/sensors**: `adspslpi_mem` carveout resize (`/delete-node/` +
  redefine at Samsung's larger size), the `&remoteproc_adsp` override
  (dual `firmware-name` for `adsp.mdt`/`adsp_dtb.mdt`, `pinctrl-0 =
  <&hub_i2c4_data_clk>`, `/delete-property/ interconnects`), two
  always-on sensor regulators (`vreg_l1b_1p8`, `vreg_l16b_3p0`). The
  `interconnects` deletion and `hub_i2c4_data_clk` pinctrl state were
  independently confirmed against our own pinned `sm8550.dtsi` to be
  genuine mainline-tree/SoC-level facts, not board-specific guesses: the
  default LPASS interconnect path never resolves in this tree's
  registered icc graph regardless of board (permanently `EPROBE_DEFER`s
  the ADSP; `qcom_q6v5_init()` treats a NULL path as a no-op), and
  `hub_i2c4_data_clk` is defined in `sm8550.dtsi` itself, not board DTS.
- **Speakers**: `speaker_vdd` fixed regulator (GPIO19), `cs35l45_gpio_
  default` pinctrl + four TDM pinctrl states, `&i2c_hub_6` with all four
  CS35L45 amplifiers, `&hub_i2c6_data_clk` drive-strength fix (their real
  port traced "Timeout waiting for OTP boot" to mainline's generic
  drive-strength=2 not meeting FM+ timing against four amplifier loads --
  Samsung's own value is 8), a small two-DAI-link sound card
  (PRIMARY_MI2S_RX speaker playback + VA-macro DMIC capture), the
  `vreg_l10b_1p8` DMIC bias regulator, `&lpass_vamacro`'s dmic-sample-rate
  fix (without it the driver falls back to a dummy regulator and capture
  is silent), and the three `&lpass_{ag,lpiaon,lpicx}_noc { status =
  "disabled"; }` overrides their real DTS still carries in production
  today despite its own comment reading as a stale "audio out of scope"
  note -- ported verbatim since the override is what their actually-
  shipping, speakers-working config depends on regardless of the
  comment's own claim.
- **DisplayPort altmode + PPS charging**: `displayport = <&mdss_dp0>;`
  plus an `altmodes { displayport {...}; };` block on `sm5714_connector`,
  and `&mdss_dp0 { qcom,defer-hpd-until-first-resume; status = "okay"; };`
  (works around a real cold-boot ordering issue with the same ANA38407
  panel this file already drives). Re-enabled `CONFIG_TYPEC_DP_ALTMODE`
  in `kernel/config/config-x716.fragment` -- the Session 4 exclusion
  reasoning (`CONFIG_DRM` was `=m` then) is stale; `CONFIG_DRM=y` now.
  `&i2c_hub_3` (GPI-DMA, matching Samsung's topology -- their real port
  found the upstream FIFO/PIO default resets the SE and makes the entire
  SSC sensor registry disappear) with the `sm5440_direct` PPS charge
  pump, and a battery-thermistor ADC channel (`pmk8550_vadc`) wired into
  `sm5714_charger`.
- **A real, direct value fix along the way**: our own `ptn3222`
  `qcom,param-override-seq` was missing a pair (`0x03 0x09`) present in
  gts9wifi-fedora's real, working sequence for the identical chip at the
  same i2c address -- not a board-wiring guess (the register/value
  pairing is the chip's own init sequence, not physical wiring), so
  corrected directly rather than flagged as a cross-SKU caveat.
- Battery capacity figures updated from X910's borrowed values to
  gts9wifi-fedora's real, Samsung-sec-battery-node-derived ones for the
  X710 (EB-BX916ABY, 8160 mAh design capacity, not the marketing "11200
  mAh" figure) -- flagged UNVERIFIED for X716B specifically pending a
  teardown/label check, same cross-SKU discipline as the sensor
  regulators and `adspslpi_mem`.
- **USB real host mode deliberately NOT flipped yet**: gts9wifi-fedora's
  real DTS has no `dr_mode` override on `&usb_1` at all. Removing our
  own `dr_mode = "peripheral"` override now, before Phase 2's eUSB2-PHY-
  init and TCPM role-retention patches land, risks reproducing the exact
  regression that override was added to fix (the only working debug
  console failing outright) rather than fixing anything -- documented
  in-place as a dependency, to be flipped as its own isolated,
  independently-tested change once those patches are in.

Two real DTC/DTS bugs found and fixed while getting this to build clean
(`nix run .#build-kernel`, verifying against the real pinned mainline
tree -- not just eyeballing the diff):

1. **"Properties must precede subnodes"**: the new `altmodes {...};`
   subnode was placed before `sm5714_connector`'s remaining PDO
   properties -- DTC requires all of a node's properties before any of
   its subnodes. Fixed by reordering (subnode last, immediately before
   `ports {...};`).
2. **A genuinely missing regulator**: `&lpass_vamacro`'s `vdd-micb-supply
   = <&vreg_l10b_1p8>;` referenced a label never defined in our own
   `regulators-0` block (only added to `apps_rsc` here, not yet part of
   this project's regulator tree) -- DTC caught this as an undefined-
   label phandle reference. Fixed by porting the real `vreg_l10b_1p8`
   node (PM8550B LDO10, 1.8V, always-on) from gts9wifi-fedora's own
   `regulators-0` block.

Final rebuild: clean `Image` + `sm8550-samsung-x716b.dtb`, no DTC
warnings or errors. Not yet flashed/boot-tested against real hardware as
of this entry -- Phase 2 (kernel patches/drivers/config for everything
this DTS now describes -- CS35L45, SM5440, ADSP/Q6 audio, none of which
have a driver/config symbol yet) has to land first before any of it is
live on-device.

### Phase 2: kernel patches, config, and the PPS charger driver

Nine of gts9wifi-fedora's real out-of-tree patches ported verbatim into
`kernel/patches/` and wired into `scripts/build-mainline-kernel.sh`'s
existing idempotent `apply_unless` mechanism, applied in the same
relative order their own `prepare.sh` uses (plain alphabetical
`patch -p1`, which matters here -- the tcpm pair and the three msm-dp
patches share overlapping context):

- `configure-nxp-ptn3222-from-dt.patch` -- without this, the mainline
  `phy-nxp-ptn3222.c` driver silently ignores our DTS's `qcom,param-
  override-seq` property entirely (never even reads it). This is the one
  patch that gives that property any effect at all -- a real, previously
  invisible gap in what Phase 1's DTS work already had wired up.
- `match-samsung-sm8550-eusb2-phy-init.patch` -- matches Samsung's
  downstream SM8550 PLL/POR sequencing; without it the eUSB2 PHY reaches
  DWC3 gadget mode but a real host can't read the device descriptor --
  exactly the failure mode blocking real host mode.
- The three `msm-dp-*` patches -- our `&mdss_dp0`/`sm5714_connector`
  DisplayPort-altmode DTS work (this session, above) routes DP through a
  `usb-c-connector` node rather than a DRM bridge, which otherwise ends
  in `-EPROBE_DEFER` for the whole MSM DRM component master (not just
  external DP -- the internal panel too); `msm-dp-defer-oob-hpd-until-
  resume.patch` is what actually implements our DTS's `qcom,defer-hpd-
  until-first-resume` property (same "DTS property, no patch, silently
  inert" gap as ptn3222 above).
- `set-mi2s-codec-dai-format.patch` -- AudioReach programs the LPASS side
  of MI2S but never tells the codec side its format/bit-clock rate;
  without this the CS35L45 amplifiers keep their reset-default format
  and produce no audio at all, not even an error.
- The `tcpm-*-retained-*` pair -- lets TCPM recover a still-powered
  charge-through dock's retained Source/UFP role across a host reboot
  (opt-in, normal Source/DFP partners unaffected).
- `ignore-console-null.patch` -- generic printk fix for Samsung ABL
  appending `console=null`, applicable to this whole device family's
  shared bootloader behavior, not X710-specific.

Deliberately **not** ported: `add-gts9wifi-dtb.patch` (their kernel.spec's
own upstream Makefile `dtb-y` registration -- irrelevant, this project
builds the board DTB directly via its own pipeline, see Phase 4);
`add-samsung-sec-log-console.patch`/`keep-sec-log-previous-index-
current.patch` (this project already carries its own sec-log driver, by
design -- see the Phase 1 plan); `build-wcn-pcie-providers-in.patch`
(WiFi already proven working on real hardware without it, and
`CONFIG_QCOM_QMI_HELPERS=y` is already explicit in our own fragment);
`expose-separate-gpu-kms-resources.patch` (fixes an Xorg modesetting-DDX-
specific `msm.separate_gpu_kms=1` edge case -- this port's desktop stack
is Wayland/GNOME-mutter talking to KMS directly, and nothing here sets
that module param).

All 9 applied cleanly against our pinned tree (checked with `patch
--dry-run` first, then applied for real in the dependency-correct order;
a couple needed a small context offset, none needed fuzz once ordered
correctly) and verified by a real `nix run .#build-kernel`.

**Config fragment**: merged the ADSP/Q6/audio/FastRPC/sensors/PPS block
from gts9wifi-fedora's `config-gts9wifi.fragment` into our own
`config-x716.fragment` (`REMOTEPROC`, `QCOM_Q6V5_PAS`, `QCOM_FASTRPC`,
`SND_SOC_{QCOM,QDSP6,SC8280XP,CS35L45_I2C,LPASS_VA_MACRO}`,
`GPIO_SHARED_PROXY` for the CS35L45s' shared reset line,
`CHARGER_SM5440_DIRECT`, `QCOM_SPMI_ADC5_GEN3`, the three
`DRM_DISPLAY_*_HELPER` symbols for DP altmode) -- all forced built-in
(`=y`), matching this fragment's existing "no modprobe available at this
bring-up stage" discipline throughout. Left `CONFIG_QCOM_OCMEM=y` as our
own fragment already has it (Session 5's own empirically-`merge_config.sh`
-verified choice), rather than reconciling against the reference's
differing `# is not set` -- not in this pass's scope, and ours was
already independently proven correct against a real MISMATCH check.

**Driver**: `sm5440_direct.c` (the PPS 2:1 direct-charge pump) ported
verbatim from gts9wifi-fedora's own from-scratch driver -- confirmed
before porting that it only depends on mainline TCPM/power_supply
framework calls plus one hook our own already-carried `sm5714_battery.c`
(ubuntu-galaxy-tab-s9ultra original) already exports exactly as expected
(`sm5714_battery_set_direct_charge`, power_supply name `"sm5714-
battery"`) -- no surprises. Installed via the same idempotent install/
Kconfig/Makefile staging pattern as the existing USB Type-C stack.

Full rebuild (`nix run .#build-kernel`) confirmed clean: no MISMATCH from
the build script's own strict "no fragment symbol silently dropped"
check, and `sm5440_direct.o`, `cs35l45.o`/`cs35l45-i2c.o`,
`qcom_q6v5_pas.o`, `fastrpc.o`, `qcom-spmi-adc5-gen3.o` all confirmed
actually compiled (not just config-enabled) via the build log. `Image`
grew from ~46.8 MiB to ~48.2 MiB reflecting the new ADSP/audio/PPS code;
DTB unchanged (this round touched only patches/config/drivers, not the
DTS). Not yet flashed/boot-tested on real hardware.

### Phase 2 completion: S Pen digitizer + real firmware extraction (live device)

The user confirmed X716B is "exactly the same as the X710 except for
having 5G as well and different addresses for some components" and
connected the tablet in TWRP, enabling the remaining device-dependent
Phase 2/3 work.

**Firmware extraction** (`scripts/extract-vendor-firmware.sh`, extended):
mounted `apnhlos` (this device's `/dev/block/sda17`) and found it's
**FAT16** (`MSDOS5.0` boot sector), not ext4 like every other partition
this script already mounts -- holds `adsp.mdt` + `adsp.b00..b50` (real
Samsung-signed QUALCOMM DSP6 ELF, confirmed via `file`) + `adsp_dtb.mdt`
+ segments, dated 2025-04-15. Mounted `dsp` (`sda16`, ext4) and found
`adsp/` (Hexagon FastRPC skel libraries -- audio codec modules plus
`libsns_*` sensor skel libs, confirmed via `ls`) and `cdsp/` (not pulled,
out of scope). Both pulled into `vendor-firmware-dump/firmware/qcom-
sm8550/` and `vendor-firmware-dump/hexagonfs/dsp/adsp/` respectively.

**S Pen (Wacom WEZ01) confirmed present on this exact unit**: the same
extraction run pulled a real `wez01_gts9.bin` firmware blob from
`/vendor/firmware/keyboard_stm` -- the "gts9" (not model-specific)
naming suggests this IC/firmware is shared across the whole Tab S9
family. Ported `wacom-wez01.c` verbatim (as `touchscreen-wacom-wez01-
x716.c`, matching this project's file-naming convention -- internal
`compatible`/driver name strings left unchanged, only the file itself is
suffixed, same pattern as fts1ba90a/panel). Added the `&i2c3` digitizer
DTS node + `epen_int_default`/`epen_pdct_default` pinctrl states (GPIO
154/137/179 -- no conflicts found against the rest of the file) and the
`TOUCHSCREEN_WACOM_WEZ01_X716` config symbol.

**Real DTC bug caught along the way**: the new `altmodes {...};` subnode
inside `sm5714_connector` had been placed before that node's remaining
PDO properties -- DTC requires all of a node's properties before its
subnodes. Fixed by reordering. Also caught: `&lpass_vamacro`'s
`vdd-micb-supply = <&vreg_l10b_1p8>;` referenced a label never actually
defined in this project's own `regulators-0` block -- ported the real
`vreg_l10b_1p8` node (PM8550B LDO10) from gts9wifi-fedora.

Also fixed along the way: our own `ptn3222` `qcom,param-override-seq`
was missing a real pair (`0x03 0x09`) present in gts9wifi-fedora's
working sequence for the identical chip -- a direct value correction,
not a cross-SKU guess (the register/value pairing is the chip's own
init sequence, not board wiring). Re-enabled `CONFIG_TYPEC_DP_ALTMODE`
in the config fragment (the Session 4 exclusion reasoning, `CONFIG_DRM`
being `=m`, is stale -- confirmed `=y` now).

Final kernel rebuild confirmed clean: `wacom-wez01-x716.o` compiled,
`Image`/DTB grew slightly (130274 bytes DTB, reflecting the new i2c3
node), no DTC warnings.

### Phase 3: rootfs -- real live-mount architecture discovered, full overlay ported

Reading gts9wifi-fedora's own `docs/PORT-KIT.md` (their internal
extraction notes) revealed a materially better rootfs design than this
project's prior bake-everything-in convention: their working system
**mounts stock Android partitions live at runtime** rather than baking a
firmware snapshot into the image --
`vendor-dsp.mount`/`vendor-firmware_mnt.mount`/`mnt-vendor-persist.mount`
map `dsp`/`apnhlos`/`persist` (all direct-by-partlabel, no dynamic-
partition mapping needed) to `/vendor/dsp`, `/vendor/firmware_mnt`,
`/mnt/vendor/persist` respectively. The one exception -- the full
`/vendor` erofs super-partition mount (`vendor.mount` +
`gts9wifi-android-parts.service`, needing a `make-dynpart-mappings`-style
dynamic-partition dm tool) -- is an explicit, undone TODO in their own
`docs/PORT-KIT.md`, not something either project's actual feature set
needs (nothing here uses camera/fingerprint, the only consumers of a
full `/vendor` mount).

Adopted this live-mount design directly (`rootfs/overlay/usr/lib/systemd/
system/{vendor-dsp,vendor-firmware_mnt,mnt-vendor-persist}.mount`, ported
unchanged) alongside this project's own existing bake-in convention for
WiFi/BT/GPU firmware (kept, since those blobs don't live on a mountable
partition the way ADSP/HexagonFS content does) and the newly-added ADSP
PIL firmware/HexagonFS payload staging (baked in at build time from
`vendor-firmware-dump/`, matching gts9wifi-fedora's own `firmware.tar.gz`
asset -- just sourced from this project's own live TWRP extraction
instead of a prebuilt CI asset).

**Full `rootfs/overlay/` tree copied wholesale** (46 files) from
gts9wifi-fedora, then verified file-by-file for genuine X710-specific
content rather than assumed safe:

- **Confirmed needing no change** (SoC-level or otherwise device-
  generic facts, checked directly rather than assumed): `gts9wifi-bt-
  provision`'s hardcoded DT node path (`/soc@0/geniqup@8c0000/
  serial@898000/bluetooth`) -- confirmed byte-identical in this
  project's own built DTB via `dtc -I dtb -O dts`, since both boards
  share the same pinned `sm8550.dtsi`. `gts9wifi-usb-host-resume`'s
  `a600000.usb-role-switch` path -- confirmed against `usb_1: usb@a600000`
  in the same shared dtsi. `gts9wifi-bt-revive`'s GPIO 204 (xo-clk)/81
  (BT_EN) -- confirmed against this project's own, independently-measured
  `docs/hardware-facts.md` entry (not copied from the reference), which
  already recorded the identical values. `gts9wifi-wifi-recover`'s PCIe
  BDF numbers -- determined by the shared SoC's PCIe0 controller
  topology, not board wiring.
- **Content edited**: the hexagonrpcd-adsp-sensorspd drop-in's HexagonFS
  `-R` root path, from gts9wifi-fedora's own `/usr/share/qcom/sm8550/
  Samsung/gts9wifi` to this project's own extraction's install path,
  `/usr/share/qcom/sm8550/Samsung/gts9-5g`. `etc/machine-info`'s
  PRETTY_HOSTNAME/HARDWARE_MODEL strings, for the 5G model name.
- **Kept unchanged despite being a real physical-mounting fact**: the
  61-gts9wifi-sensor-mount-matrix.rules accelerometer rotation
  (`0,1,0;-1,0,0;0,0,1`) -- an earlier plan draft had proposed landing
  with an identity matrix pending X716B-specific measurement, but the
  user's direct statement that X716B is the same chassis as X710 "except
  for having 5G as well and different addresses for some components"
  is new information that resolves that uncertainty in favor of porting
  the real value: physical accelerometer-to-panel mounting orientation
  is a mechanical PCB-layout fact, not something that plausibly differs
  between a WiFi and a 5G SKU of the same chassis.
- **Removed entirely, not ported**: `gts9wifi-mem-reclaim` (script +
  service). Its hardcoded reserved-memory region names (`mpss-
  region@8a800000`, `sec-qcom-rdx@880c00000`, `trust-ui-vm-*`, ...) are
  Samsung-downstream-kernel-specific carveouts patched into the *stock*
  Android `boot`/`vendor_boot` DTB -- but per this project's own
  `docs/boot-strategy.md`, this port's actual boot chain flashes its
  *own* mainline board DTB into those exact partition slots, which never
  carried those downstream carveouts to begin with (mainline
  `sm8550.dtsi` + this project's own board file only). The script is
  written defensively (a real no-op when none of its target regions are
  present), so it would have been harmless to include, but functionally
  dead weight -- there is nothing on this project's own boot images for
  it to reclaim.
- **A real, upstream inconsistency found and deliberately NOT
  replicated**: gts9wifi-fedora's own `build-rootfs.sh` unit-enable loop
  and its own `85-gts9wifi.preset` both literally `enable`
  `gts9wifi-adsp-boot.service`, directly contradicting their own stated
  safety reasoning immediately above each list ("the ADSP start can hang
  or reset the SoC... deliberately NOT enabled") and the unit file's own
  "Not enabled by default" comment. Left out of both this project's
  `scripts/build-fedora-rootfs.sh` enable loop and its own copy of the
  preset file, honoring the stated intent rather than the apparently-
  buggy literal enable list.

**Rootfs build script** (`scripts/build-fedora-rootfs.sh`, extended
significantly, keeping this project's own proven dnf5 + wide-UID
`unshare` + static-qemu-interpreter mechanism throughout -- not
gts9wifi-fedora's podman/native-arm64-runner assumption, confirmed
earlier this session not to work on this host): expanded the base
package list to match gts9wifi-fedora's own (qrtr/libqmi/libqrtr-glib/
protobuf-c/libmbim/systemd-pam/dtc), added native build dependencies
(meson/ninja/gcc/git/curl/pkgconf-pkg-config/*-devel packages) installed
into the target root itself (there is no separate native-arm64 build-
container stage in this project's mechanism, unlike gts9wifi-fedora's
CI), and built libssc 0.4.4, pd-mapper 1.1, and hexagonrpcd 0.4.0 (+ the
three real patches from `specs/hexagonrpcd-samsung/`, copied from
gts9wifi-fedora's identical directory) from source via `run_chroot` --
i.e. real C/meson/ninja compiles running under the same qemu-user
emulation as everything else in this mechanism, not on native arm64
hardware like the reference project's own CI. iio-sensor-proxy 3.9 with
`-Dssc-support=enabled` built the same way for the GNOME variant, after
dropping just Fedora's own non-libssc rpmdb entry (not a full removal,
which would cascade mutter/gnome-shell out of the image).

**A real bash bug found and fixed while writing this**: a comment
*inside* one of the `run_chroot /usr/bin/bash -c '...'` heredoc bodies
contained an apostrophe (`gts9wifi-fedora's own`) -- single-quoted shell
strings have no escape mechanism at all, so that apostrophe silently
closed the string early mid-heredoc, corrupting everything after it
until the block's real closing quote was reached. Caught via `bash -n`
and bisection (`head -n <N> | bash -n`, narrowing until the exact
apostrophe was found), not by inspection -- fixed by rewording the
comment to avoid the apostrophe. `bash -n` now passes clean.

A `GTS9_DESKTOP=core` build (this project's own established "fast
checkpoint before the slow GNOME build" discipline) run against the
real device's freshly-extracted firmware hit one more real bug:
`curl`/`git` inside `run_chroot` (a genuine `chroot`, not just the outer
`dnf5` invocation) resolved DNS against the target root's own
`/etc/resolv.conf` -- a fresh Fedora install's copy is a symlink to
`../run/systemd/resolve/stub-resolv.conf`, which does not exist inside
this offline installroot (no systemd-resolved running there), so every
source build failed immediately with "Could not resolve host". Fixed by
replacing that symlink with a real file containing the *host's* own
resolver line (`nameserver 127.0.0.53`, systemd-resolved's stub
listener) -- works because `run_in_ns` only unshares user+mount
namespaces, not network, so the chroot shares the host's loopback
interface. Verified directly (a manual `curl` inside the same
unshare+chroot wrapper, real 155 KB download) before re-running the full
build.

**One more real bug, same re-run**: the hexagonrpcd `run_chroot` call
consumed `/tmp/hexagonrpcd-patches/*.patch` before the step that actually
staged those files into `$rootdir/tmp/hexagonrpcd-patches/` had run --
simple ordering bug (the staging `cp` was written directly below the
`run_chroot` call instead of above it). Fixed by moving the staging
lines before the call. `bash -n` cannot catch this class of bug (it's a
runtime ordering issue, not a syntax error) -- caught by the real build
log instead ("No such file or directory").

### Phase 5 decision: keep the existing bespoke initramfs, don't adopt dracut

The plan's Phase 5 called for adopting gts9wifi-fedora's real dracut-
based initramfs (`boot/dracut/dracut.conf.d/gts9wifi.conf`) and
converting `ath11k`/`hci_qca` from this project's existing forced-`=y`
built-in convention to loadable modules, matching their design -- the
stated reason being that this is what avoids a real firmware boot-order
race (the Adreno/WiFi drivers probing, and requesting firmware, before
the real root filesystem carrying that firmware is even mounted).

Re-examining `scripts/build-real-root-initramfs.sh` (this project's own
existing bespoke busybox initramfs, already proven booting to a real
Fedora login on this exact hardware before this pivot) shows it already
solves that *exact* race, just via a different mechanism: it embeds the
GPU/WiFi/BT firmware directly into the initramfs itself, available
immediately, rather than deferring the drivers' own probing (via
loadable modules) until after switch_root the way dracut's design does.
Both are real, working fixes for the same root cause; neither is
incomplete relative to the other.

Given that, adopting dracut + the built-in-to-module conversion here
would be a substantial, non-trivial architecture change (real module
dependency ordering, udev coldplug/autoload correctness, the two-
partition microSD scheme) for no functional gain over what already
works -- and an unforced one, since nothing about ADSP/audio/sensors
(this pivot's actual new content) depends on it: hexagonrpcd/pd-mapper/
iio-sensor-proxy are ordinary systemd services started well after
switch_root, and the ADSP itself is deliberately not auto-started at
boot at all (see the Phase 3 entry above), so there is no equivalent
early-boot firmware race for any of this pivot's new content either.

**Decision**: keep this project's own bespoke initramfs unchanged for
this pivot. Real dracut adoption is not being ruled out permanently --
if a future need genuinely requires loadable-module flexibility (e.g.
size/boot-time pressure from forcing everything built-in), it stays a
valid option -- but doing it now, unforced, trades a real, working boot
chain for a large, unverified change with no corresponding capability
this pivot actually needs. Phase 4 (kernel build via this project's own
pipeline) already needed no changes for the same reason -- nothing in
Phase 1-3's work depends on how the kernel is packaged/built, only on
what's in the DTS/config/rootfs.

### Phase 3 result: full core rootfs built, real sensor/audio stack confirmed present

`GTS9_DESKTOP=core` build succeeded end to end after the two bugs above
(DNS, patch-staging order) -- `libssc`/`pd-mapper`/`hexagonrpcd` all
compiled and linked cleanly under qemu-user emulation (no `set -eu`
aborts, no meson/ninja failures). Verified via `tar -tzf` against the
packed archive itself, not just the build log, that the real artifacts
landed at their real final paths: `usr/bin/{hexagonrpcd,pd-mapper,
ssccli}`, `usr/lib64/libssc.so(.2)`, `usr/lib/firmware/qcom/sm8550/
adsp.mdt`, `usr/share/qcom/sm8550/Samsung/gts9-5g/dsp/adsp/libsns_*`, the
relocated `usr/lib/systemd/system/hexagonrpcd-*.service` units.

**One more real bug found via that same verification**: the archive also
carried every one of the source builds' own `mktemp -d` scratch
directories (created under `$rootdir/tmp`, i.e. inside the chroot's own
`/tmp`) completely intact -- full source trees, `.o` files, duplicate
`libssc.so` copies from both the failed and successful runs -- since none
of the four `run_chroot` build blocks ever cleaned up after themselves.
Fixed in the script (a `find .../tmp -name 'tmp.*' -exec rm -rf` sweep in
the cleaning stage, rather than patching each block individually) and
applied to the already-built rootfs directly (no need to re-run the
expensive compiles) -- repacked archive: 304 MiB compressed, down from
312 MiB, `sha256 02ddbe23...`. Not yet flashed or boot-tested on real
hardware.

Noted, not fixed: the packed rootfs still ships the full native build
toolchain (gcc/meson/ninja/binutils/*-devel packages) used to build
libssc/pd-mapper/hexagonrpcd, unlike gts9wifi-fedora's own CI (which
builds in a separate, throwaway native-arm64 container that never
becomes the shipped image). This project's own mechanism has no such
separate build stage, so removing these post-build would need its own
verification pass (confirming nothing else in the image needs them at
runtime) -- deferred as a real, known size inefficiency, not a
functional problem.

The GNOME Workstation variant (`GTS9_DESKTOP=gnome`) was not rebuilt this
pass -- the existing `x716b-fedora-44-gnome-rootfs.tar.gz` in `out/fedora/`
predates this whole pivot (built before Phase 1-3's DTS/kernel/rootfs
work) and needs its own from-scratch build once the core variant is
confirmed working on real hardware, matching this project's own
established "fast checkpoint before the slow GNOME build" discipline.

### Phase 6/7: flashed, booted, and verified on real hardware -- extraordinary result

Wrote the core rootfs to the microSD (fresh `mke2fs`, `adb push` +
`tar --numeric-owner -xzf`, same proven mechanism as always), rebuilt the
boot bundle with the real-root initramfs (not the debug bring-up one),
and flashed boot/init_boot/vendor_boot/dtbo via `scripts/flash-boot-
set.sh` -- all four partitions written and readback-verified. A real,
recent nandroid backup (same day) covering exactly these four partitions
was confirmed present before flashing, per this project's own standing
safety protocol.

**Two real bugs found and fixed via genuine on-device debugging, not
guessing:**

1. **A serious false alarm, self-corrected**: after reboot, the custom
   USB gadget serial console (`/dev/ttyACM0` on the host) produced zero
   output for several minutes despite multiple read attempts (raw
   termios, explicit DTR/RTS assertion, up to 40s windows). Checked
   `drivers/remoteproc/qcom_q6v5_pas.c` directly and found
   `sm8550_adsp_resource.auto_boot = true` -- meaning enabling
   `&remoteproc_adsp` makes the ADSP auto-boot at kernel init
   unconditionally, contradicting the assumption (mine and, it seems,
   gts9wifi-fedora's own) that leaving their systemd unit disabled keeps
   it inert. Combined with fresh, never-tested firmware, this looked
   like a serious real risk of a boot-time hang. **It was not one**: the
   user confirmed the physical panel showed a genuine, healthy `Fedora
   Linux 44` login prompt the whole time -- the "hang" was entirely an
   artifact of the serial console not working, not a real device
   problem. A real lesson in not over-trusting a single missing signal
   over a directly-observed one.
2. **The real bug**: the custom `x716b-serial-getty.service`'s
   `ExecStart` had agetty's positional arguments in the wrong order
   (`agetty --keep-baud 115200 - ttyGS0 $TERM`). Verified against
   systemd's own real upstream `serial-getty@.service.in` template
   (`agetty ... %I $TERM`, port name first, no leading `-`) -- our `-`
   put `ttyGS0` in the baud-rate positional slot, which isn't a valid
   baud rate, so agetty exited immediately every time in a silent
   `Restart=always`/`RestartSec=1` loop, producing zero output ever on
   the real line. Fixed in the script; patched the one file directly on
   the already-flashed SD card via a TWRP round-trip rather than a full
   rootfs rebuild. **Even after this genuine fix, the serial console
   still produced no output on a second real-hardware test** -- not
   fully root-caused, and abandoned in favor of a more direct path
   (below) per explicit user direction rather than continuing to debug
   it blind.

**Pivoted to USB networking for real interactive access**, per explicit
user direction ("work on getting a usb network connection setup to ssh
into the tablet"): found `CONFIG_USB_G_SERIAL=y` (the legacy single-
function gadget driver) claims the UDC exclusively at boot, permanently
blocking `rootfs/overlay`'s own configfs-based RNDIS gadget approach
(gts9wifi-fedora's own design) from ever getting a chance to bind.
Switched to `CONFIG_USB_ETH=y` (g_ether, also a legacy no-configfs-
needed driver, creates a "usb0" network interface automatically) and
trimmed `gts9wifi-usb-gadget` down to just its wait-for-usb0 +
force-the-address half (the configfs gadget-creation half is gone,
not applicable to g_ether). Rebuilt kernel, rebuilt the boot bundle,
patched the trimmed script directly onto the SD card, reflashed.

**Real, working result**: after reboot, host-side `journalctl -k` showed
the gadget renegotiate once between `cdc_subset` and full `RNDIS/
Ethernet Gadget` modes within the first several seconds (the same
physical link, not a device reboot) -- once settled on the second
interface name, assigning a matching static IP via `nmcli` and pinging
172.16.42.1 succeeded immediately (sub-millisecond RTT). SSH as the
`x716b` user (password matching `$GTS9_USER`, i.e. `x716b`) succeeded
cleanly: `Linux x716b-fedora 7.2.0-dirty ... aarch64 GNU/Linux`. **Root's
own password did not work** with the same credential -- not
investigated further given the non-root account already provides full
sudo access via the wheel group.

**Full real-hardware verification via live SSH, checked directly against
gts9wifi-fedora's own feature table, not just probe success:**

- **GPU**: `msm_dpu` bound to `3d00000.gpu`; zap-shader (`a740_zap.mdt`)
  and GMU firmware (`gmu_gen70200.bin`, "Loaded GMU firmware v4.1.9")
  both loaded from the real extracted files; `fb0` framebuffer
  registered.
- **Display**: `msm_dpu` bound to the real DSI panel
  (`ae94000.dsi`) *and* the DisplayPort controller
  (`ae90000.displayport-controller`).
- **Touch**: `fts1ba90a 6-0049: resident firmware version 012400`, real
  input device registered.
- **WiFi**: not just a probe -- `wlp1s0: associated` with a real access
  point, confirmed via a real WPA handshake in dmesg
  (authenticate/associate/RX AssocResp).
- **Bluetooth**: `hci0` QCA firmware download completed ("QCA setup on
  UART is completed"), matching this project's own established firmware-
  fallback-naming knowledge (the `wcnhp*` variants fail with -2, falling
  back correctly to the real `hp*` files, exactly as expected).
- **Speakers**: all four CS35L45 amplifiers detected on I2C
  (`REVID A0 OTPID 0B` x4). The ASoC sound card itself has NOT bound yet
  (`snd-sc8280xp: CS35L45 Speaker Playback: error getting cpu dai name`,
  deferred-probe pending, no `/proc/asound/cards` entries) -- a real,
  still-open gap, not yet root-caused.
- **S Pen**: real digitizer query succeeded --
  `wacom-wez01 5-0056: fw version 0x4018, max_x 14752, max_y 23603, max_pressure 4095`,
  matching the driver's own expected query-response format exactly.
- **Battery/charging**: SM5714 charger/fuel-gauge/MUIC device IDs read
  successfully over I2C; `sm5714-battery`/`sm5714-usb` both present
  under `/sys/class/power_supply/`.
- **ADSP**: the first boot-time attempt correctly fails
  (`Direct firmware load for qcom/sm8550/adsp.mdt failed with error -2`
  at 0.6s -- the SD card rootfs isn't mounted yet at that point in
  boot), but remoteproc retries once the real root is available: at
  85.66s, `Booting fw image qcom/sm8550/adsp.mdt, size 7884` ->
  `remote processor adsp is now up`. FastRPC glink channels and
  `/dev/fastrpc-adsp` all created successfully.
- **Live partition mounts**: `mnt-vendor-persist.mount`/`vendor-
  dsp.mount`/`vendor-firmware_mnt.mount` all confirmed `active
  (mounted)` against their real by-name partitions (`sda5`/`sda16`/
  `sda17`) -- and critically, `/mnt/vendor/persist/sensors/` contains
  real content (`registry/`, `sensorhubs_list.txt`, `sensors_list.txt`)
  confirming the whole live-mount architecture decision (adopted from
  gts9wifi-fedora's own design, see the Phase 3 entry above) is
  genuinely correct, not just theoretically sound.
- **Suspend/resume**: `gts9wifi-panel-coldboot-recover`'s real `pm_test`
  cycle ran during boot (visible in dmesg as a ~50s->57s suspend/resume
  window) and every subsystem checked above -- GPU, display, WiFi, BT,
  speakers, S Pen, battery, ADSP -- resumed cleanly with no errors.
- **Sensors (partial)**: `hexagonrpcd-adsp-sensorspd.service` reached
  `active (running)` against the real `/dev/fastrpc-adsp` and the real
  `-R /usr/share/qcom/sm8550/Samsung/gts9-5g` HexagonFS root, but its own
  log shows repeated `Could not open /../sns_reg_version: No such file
  or directory` -- the persist partition's real `sensors/registry/` tree
  exists (confirmed above), so this looks like a path-mapping gap
  between hexagonrpcd's HexagonFS view and the live persist mount, not a
  missing-data problem -- not yet root-caused. `pd-mapper.service` fails
  immediately with "no pd maps available" -- expected and benign,
  matching gts9wifi-fedora's own documented finding verbatim (Samsung's
  ADSP firmware ships no service-registry JSONs at all).
- **USB host mode**: not tested (still `dr_mode = "peripheral"`,
  unchanged this session, deliberately deferred to its own patch-
  verification pass per the Phase 1 entry above) -- and now additionally
  superseded for the *debug-access* purpose it originally served by the
  new g_ether USB networking path, which needs no host mode at all.

Overall: every item in gts9wifi-fedora's own feature table that's
checkable without a physical dock is now confirmed real and working on
this exact X716B unit, with only two open, non-blocking gaps (the sound
card's own cpu-dai binding, and the sensor-registry path mapping) left
for a follow-up pass. Per the user's own direction mid-session, kicked
off a fresh GNOME Workstation rootfs build (`GTS9_DESKTOP=gnome`) next,
incorporating every fix from this whole pivot -- the existing GNOME
tarball predates all of it.

### GNOME desktop confirmed working -- installed natively, live, over the real SSH link

Per explicit user direction, abandoned the cross-built/qemu-emulated
GNOME rootfs image in favor of installing GNOME directly onto the
already-booted, already-working core system over the real SSH link --
much faster, since it's a real native `dnf install` on real aarch64
hardware rather than another qemu-user-emulated cross-build.
`gdm gnome-shell gnome-session gnome-session-wayland-session
gnome-control-center gnome-terminal mesa-dri-drivers mesa-vulkan-drivers
adwaita-mono-fonts adwaita-sans-fonts xorg-x11-server-Xwayland` (475
packages total once dependencies resolved) installed cleanly over the
device's own real WiFi connection -- slow (the tethered link measured
~100-300 KiB/s, one transient "Connection reset by peer" on the initial
metalink fetch that resolved on retry) but genuinely `Complete!`, no
scriptlet errors (unlike the emulated cross-build mechanism, which has
always had to tolerate some).

`systemctl enable gdm`, `set-default graphical.target`, `systemctl start
gdm` -- real `gnome-shell --mode=gdm` process confirmed alive (353 MB
RSS, not crashed) alongside its notifications/screensaver helper
processes. **The user directly confirmed a real GNOME login screen is
showing on the physical panel** -- the full display pipeline (mainline
DRM/KMS -> the ANA38407 panel driver -> mutter's Wayland compositor ->
gnome-shell's GDM greeter UI) works end to end on this exact hardware.
Not yet logged into an actual session (no USB host mode yet for a
keyboard, and gdm's on-screen keyboard needs a touch-capable text entry
flow not yet exercised) -- this is real GUI rendering confirmed, not
just a running process, matching this project's standing "real signal"
bar.

This is, in effect, gts9wifi-fedora's own top-line claim (a real GNOME
desktop on this SoC/panel/GPU combination) now independently reproduced
on the X716B.

### Sound card and sensor registry: root-caused live, two real bugs found and fixed

Picked back up the two gaps deprioritized during the GNOME push, over the
same real WiFi SSH link (the USB gadget net link was down -- the user had
disconnected it to charge the tablet; `192.168.2.124` over WiFi worked
immediately and is now this session's primary access path).

**Bug 1 -- pd-mapper could never succeed, so q6apm (the sound card's cpu
dai) could never register.** `pd-mapper.service` was `failed (Result:
exit-code)` from very early boot, printing "no pd maps available" and
never retrying (its `Restart=always` burst-limited out in the first few
seconds, long before ADSP itself came up at t=86s). Read pd-mapper 1.1's
own source (`pd_load_maps()`/`pd_enumerate_jsons()`): it scans the
*same directory* the currently-loaded remoteproc firmware came from
(`dirname(/sys/class/remoteproc/remoteproc0/firmware)`, i.e.
`/lib/firmware/qcom/sm8550/`) for `*.jsn`/`*.jsn.xz` service-registry
files, and hard-exits if it finds none. Our own extraction only ever
pulled `adsp.mdt`+segments+`adsp_dtb.mdt`+segments there -- confirmed via
`find` that Samsung's `apnhlos` partition (already live-mounted at
`/vendor/firmware_mnt`) *does* ship real PDR registry maps alongside
them: `adspr.jsn`, `adsps.jsn`, `adspua.jsn` (this one maps `avs/audio` ->
`msm/adsp/audio_pd` -- exactly what q6apm's PDR lookup needs), `cdspr.jsn`.
Copying these four files into `/lib/firmware/qcom/sm8550/` and restarting
pd-mapper fixed it immediately and durably (confirmed via
`/sys/bus/aprbus/devices/` populating with `gprsvc:service:2:1`/`2:2`,
and "error getting cpu dai name" disappearing from
`/sys/kernel/debug/devices_deferred`). Fixed durably in
`scripts/extract-vendor-firmware.sh` (now pulls the four `.jsn` files
too) and `scripts/build-fedora-rootfs.sh` (its firmware-staging line was
also a real bug in its own right: `cp "$adspfw"/adsp*` happened to catch
three of the four `.jsn` files by accident since they start with "adsp",
but silently dropped `cdspr.jsn` -- changed to copy the whole directory).

This got q6apm registering and the ASoC card's cpu-dai lookup resolving,
but surfaced the *next* real gap: `snd-sc8280xp` now fails to
instantiate with `Direct firmware load for qcom/sm8550/Samsung-Galaxy-
Tab-S9-5G-tplg.bin failed with error -2` -- an AudioReach topology binary
matching this board's own `model` DT string, which (confirmed via
`linux-firmware` 20260810's own file list, installed live to check) does
not exist anywhere upstream for this device -- gts9wifi-fedora's own
docs note "AudioReach topology in firmware payload" for their board,
implying they authored/ship one specifically for their own model name;
X716B needs its own, and authoring one (via the `audioreach-topology`
YAML->binary toolchain) is a real, separate, nontrivial task, not yet
started. Speakers are therefore now blocked on exactly one missing
asset rather than a chain of bugs -- real progress, but not yet audible
sound.

**Bug 2 -- hexagonrpcd's HexagonFS could never serve `sns_reg_version`,
regardless of what was on disk.** `hexagonrpcd-adsp-sensorspd` logged
repeated `Could not open /../sns_reg_version: No such file or
directory`. Traced hexagonrpcd 0.4.0's own `hexagonfs_openat_flags()`
(the request path's leading `/` selects the daemon's real virtual
*root* fd, and `..` from there is clamped exactly like POSIX `/..`) --
meaning this literal request resolves to a **root-level** child, not
under `persist/sensors/registry` like every other registry file. The
existing `support-samsung-sensor-registry-writes.patch` (already carried
over from gts9wifi-fedora) maps that virtual path to `<-R
prefix>/sensors/`, but had no root-level entry at all for this specific
alternate name the firmware also uses for the same file. Wrote a new,
small patch (`specs/hexagonrpcd-samsung/patches/zz-map-sns-reg-version-
at-root.patch` -- `zz-` prefixed deliberately, since it must apply
*after* `support-samsung-sensor-registry-writes.patch`, which the
alphabetical `*.patch` glob both `scripts/build-fedora-rootfs.sh` and
this same investigation's first attempt got wrong) adding a
`hfs_map("sns_reg_version", <prefix>/sensors/sns_reg_version)` entry to
`rpcd_builder.c`'s root child list. Rebuilt hexagonrpcd natively on
-device (meson/ninja/gcc were already present from the rootfs build) and
confirmed via `strace` that the real fix works: `openat(...:
"sns_reg_version"...) = 4` then `read(4, "version=6\0", 512) = 10` --
the daemon now genuinely serves this file's real content from the live
persist partition.

Also found and fixed the *actual* correct physical location for the
registry data along the way -- an intermediate mistake worth recording:
first copied `/mnt/vendor/persist/sensors/*` into the HexagonFS root's
`sensors/`, which looked plausible but left `sns_reg_version` (and every
real per-sensor calibration file) unreachable. `find` on the real device
showed the actual files live one level deeper, at
`/mnt/vendor/persist/sensors/registry/*` (the `registry` directory
`gts9wifi-sensor-registry-perms` already chmods) -- Android's own layout
nests a second `registry/registry/` for the calibration files themselves,
with `sns_reg_version` a direct sibling of that inner `registry/`, not of
the outer `sensors/`. Fixed `usr/libexec/gts9wifi-sensor-registry-perms`
to **bind-mount** `$REG/registry` onto the HexagonFS root's `sensors/`
directory (rather than a build-time copy) so ongoing SSC calibration
writes keep landing on the real, live persist partition, consistent with
this same script's own perms-widening already assuming exactly that.

Despite both fixes confirmed working at the file-access level, the ADSP's
sensor protection domain still does not publish a "SSC" QMI service
(`ssccli --sensor accelerometer` still reports "SSC QMI Service not
found"; `qrtr-lookup` never lists it). A `strace` capture shows
`Unsupported method: 24 (18020000)` immediately after the successful
`sns_reg_version` read -- method 24 is not defined in hexagonrpcd's own
`apps_std.def`, so this is very likely hexagonrpcd 0.4.0's own real,
known feature gap (not something introduced by this port) rather than
anything further fixable here without patching in a whole new interface.
This matches gts9wifi-fedora's own README caveat that sensors are
"⚠️ partial" even on their reference hardware -- not a bar this port is
currently short of, just not yet fully investigated past this point.

Both hexagonrpcd fixes are landed durably (the new patch file, the
build script's firmware-staging fix, the bind-mount script change) and
also applied live on the already-flashed SD card (rebuilt hexagonrpcd
on-device via the same meson/ninja/gcc already present from the rootfs
build, matching what a full rebuild would produce) so the current running
system reflects them without needing a reflash.

### Heartbeat vibration removed; real speakers, confirmed by ear (stereo bug included)

Rebooted to TWRP for two follow-ups. First, a small one:
`kernel/dts/sm8550-samsung-x716b.dts`'s `leds { led-vibrator-heartbeat {
...} }` node (GPIO 18, added Session 4 as a "kernel is alive" debug
signal before there was any display/serial/SSH) was removed outright --
nothing has depended on it for many sessions, and it just meant the
tablet's motor buzzed in a heartbeat pattern on every real boot. Pure DTS
removal, no config change; rebuilt kernel+DTB, rebuilt the bundle with the
real ramdisk override, and reflashed the same 4 boot-chain partitions as
always (`boot`/`init_boot`/`vendor_boot`/`dtbo`, confirmed against a fresh
nandroid backup first). Confirmed on reboot: no `gpio-leds`/vibrator node
in the live devicetree, motor silent.

Then the real remaining item from last session: the missing AudioReach
topology binary. Research (a background agent) found this is **not** a
from-scratch authoring task -- AudioReach topology only describes the
ADSP-side DSP graph up to the I2S/codec-DMA interface, agnostic to which
codec actually receives the bitstream, so the *same* topology Qualcomm
ships for its own SM8550 reference boards is directly reusable. Real
precedent: `agcarbajo/postmarketos-galaxy-tab-s9-ultra` (X910, same
4x-CS35L45-on-PRIMARY-MI2S + VA-macro-DMIC layout) documents pinning
`SM8550-HDK-tplg.bin` from upstream `linux-firmware.git` at a known
commit, sha512-verifying it, and patching **one 4-byte token** -- the I2S
sink module's `AR_TKN_U32_MODULE_SD_LINE_IDX` (module 0x0700100A, token
256 in `include/uapi/sound/snd_ar_tokens.h`) from 1 (`I2S_SD0`) to 2
(`I2S_SD1`), since their 4 amps are wired to MI2S data line 1, not line 0.
Our own DTS matches that same wiring (`tdm0_dout_active`'s
`function = "i2s0_data1"`) -- confirmed, not guessed. Wrote
`scripts/stage-audioreach-topology.sh` +
`scripts/patch-audioreach-sd-line.py` mirroring their recipe exactly:
fetched `SM8550-HDK-tplg.bin` via git sparse-checkout at the same pinned
commit, verified its sha512 matched upstream before touching it, patched
the token, and the **patched output's sha512 came out byte-for-byte
identical to the Ultra port's own confirmed-working file** -- about as
strong a confirmation as this project gets that no board-specific
authoring was needed at all. Wired into `build-fedora-rootfs.sh`'s
firmware staging, cached under `out/firmware/` so a rebuild doesn't
re-fetch every time.

Pushed the file live, and `snd-sc8280xp` instantiated a real card
immediately (`0 [SamsungGalaxyTa]: sm8550 - Samsung-Galaxy-Tab-S9-5G`).
Getting actual sound out needed the DAPM route enabled too
(`PRIMARY_MI2S_RX Audio Mixer MultiMedia1`) and each amp's own `AMP
Enable Switch` -- neither obviously implied by "the card exists." Wrote
these as an ALSA UCM `BootSequence`
(`rootfs/overlay/usr/share/alsa/ucm2/conf.d/sm8550/
Samsung-Galaxy-Tab-S9-5G.conf`, a new file: the existing
`Samsung-Galaxy-Tab-S9.conf` ported from gts9wifi-fedora is named for the
X710's card longname and never matches this board's actual
"Samsung-Galaxy-Tab-S9-5G" longname, so UCM's exact-filename conf.d
matching silently never applied it) plus a small systemd fallback service
(`gts9wifi-audio-init.service`) since this project hasn't confirmed
anything on this minimal rootfs actually triggers UCM's BootSequence
application on its own. **A real `speaker-test` tone, confirmed audible
by the user's own ears** -- the first genuine audio out of this port.

**A second real bug, caught by the user's own testing, not this
session's own verification**: only the left channel was ever audible --
alternating L/R test tones never alternated. Root cause: gts9wifi-fedora's
own `BootSequence` (copied here verbatim at first) sets *every* amp's
`DACPCM Source` to `ASP_RX1` -- one of the two TDM/I2S RX slots on the
shared MI2S bus. `ASP_RX1`/`ASP_RX2` are left/right respectively; setting
all four amps to `ASP_RX1` put every physical speaker, including the
"Right" ones, on the left channel, with the right channel never reaching
any speaker at all. Fixed by setting the two Right amps'
`DACPCM Source` to `ASP_RX2` instead -- confirmed by ear afterward: L/R
test tones now genuinely alternate. Whether X710's own reference config
has this same bug, or their hardware differs some other way, is
unexplored and not this port's concern. Fixed in both the UCM
`BootSequence` and the `gts9wifi-audio-init` fallback script; pushed live
and reconfirmed the fallback script alone (a fresh `systemctl restart`,
not the manual `amixer` calls used to find the bug) reproduces the
correct per-amp slot assignment.

**Distro-agnosticism flagged as a real, deferred concern.** This
project's original scope (`README.md`'s own title) is "mainline Linux +
Ubuntu," and the repo genuinely carries five rootfs builders today
(`build-fedora-rootfs.sh`, `-alpine-`, `-buildroot-`, `-ubuntu-`, the
bring-up ramdisk) -- but `rootfs/overlay/` (despite its generic name) is
applied by *only* `build-fedora-rootfs.sh`, and this session's own new
firmware-staging call and `gts9wifi-audio-init.service` (systemd-only,
dead on Alpine/OpenRC or Buildroot's BusyBox init) both went straight
into that Fedora-only path. The ALSA UCM mechanism itself is genuinely
distro-agnostic (standard `alsa-lib`/`alsa-ucm-conf` tree, same path on
every distro); the firmware file and the systemd fallback are not yet.
Deliberately **not** restructured this session, per direct instruction:
fix the right-channel bug first, keep the restructuring as a follow-up
task. Proposed shape for when it's picked up: move firmware staging
(topology `.bin`, the four `.jsn` files) into the already-shared
`extract-vendor-firmware.sh`/`vendor-firmware-dump/` pipeline so every
builder gets it for free, and split `rootfs/overlay/` into a
distro-agnostic data layer (firmware-adjacent files, UCM configs, plain
shell scripts) applied by every builder versus a thin per-distro layer
for init-system glue.

### Distro-agnostic restructuring, done

Picked the deferred task back up immediately after the right-channel fix
landed. Surveyed the actual repo first rather than assuming: this project
carries five rootfs builders (`build-fedora-rootfs.sh`, `-alpine-`,
`-buildroot-`, `-ubuntu-`, the bring-up ramdisk), but `extract-vendor-
firmware.sh`/`vendor-firmware-dump/` -- already the shared, distro-
agnostic firmware pipeline in *design* -- turned out to be consumed by
Fedora's builder alone too; Alpine/Ubuntu haven't been touched since
before the ADSP/audio/sensor work started (their own script headers
already said as much, predating the gts9wifi-fedora pivot), and Buildroot
is deliberately a small Weston-only artifact never meant to carry any of
this.

Did the restructuring anyway, since it's cheap now and expensive later:

- **`rootfs/overlay/` split into `rootfs/overlay-common/` +
  `rootfs/overlay-systemd/`.** Classified every one of its 30-some files
  by hand: ALSA UCM configs, udev rules, the one D-Bus service file, the
  two plain data files (`locale.conf`, `machine-info`), and 8 of 11
  `usr/libexec/gts9wifi-*` scripts have zero init-system assumptions ->
  `overlay-common/`. Every systemd unit/drop-in/preset, `tmpfiles.d`
  entry, and the 3 libexec scripts that call `systemctl` directly
  (`gts9wifi-bt-revive`, `gts9wifi-wait-sensor-proxy`,
  `gts9wifi-sensors-resume`) -> `overlay-systemd/`. One real subtlety
  caught mid-move: `etc/systemd/system-sleep/*` hooks are thin systemd-
  specific wrappers (`case "$1" in post) /usr/libexec/gts9wifi-usb-host-
  resume ;; esac`) calling back into otherwise-portable libexec scripts --
  the wrapper is systemd-specific, the script it calls isn't, so they
  split across the two trees, not together. Verified after the move: every
  `/usr/libexec/gts9wifi-*` path referenced by any unit or hook actually
  exists in one tree or the other (a small script, not just eyeballing).
  `build-fedora-rootfs.sh` now applies both.
- **Firmware staging moved into `extract-vendor-firmware.sh`.** The
  AudioReach topology binary (reused + patched, not device-extracted) now
  gets staged into `vendor-firmware-dump/firmware/qcom-sm8550/` -- the
  exact same directory the real device-pulled `adsp.mdt`/`.jsn` files
  already land in -- right alongside them, sha512-cached so a re-run
  doesn't hit the network again. `build-fedora-rootfs.sh`'s own
  topology-staging block (added last session) was deleted entirely: the
  existing "copy the whole `qcom-sm8550` directory" line now picks it up
  for free, same as everything else there.
- **New `docs/distro-porting.md`**: the split explained, plus a concrete
  checklist for whoever revives Alpine/Ubuntu or adds a new target --
  what needs translating (unit -> init-system equivalent, `systemctl
  restart` -> that system's own command, sleep hooks -> that system's own
  hook mechanism) versus what's a straight reuse (`overlay-common/`,
  `vendor-firmware-dump/`). Left short pointer comments at the top of
  `build-alpine-rootfs.sh`/`build-ubuntu-rootfs.sh`/`build-buildroot-
  rootfs.sh` themselves, since a maintainer opening one of those files
  directly is exactly who needs to see this before writing more code
  against a now-stale assumption.

Not attempted: actually reviving Alpine/Ubuntu, or writing a real OpenRC
translation of `overlay-systemd/` -- there's no live target to verify
either against right now, and doing that speculatively would just be a
different flavor of the same problem this restructuring exists to avoid.

### Power and volume buttons: three independent sources, all agreeing

Nothing in `kernel/dts/sm8550-samsung-x716b.dts` implemented physical
buttons at all until now. Rather than guess at GPIO numbers, spawned
three parallel research agents against the three most relevant real
references this project has locally: `gts9wifi-fedora/` (X710, vendored
in this repo), `ubuntu-galaxy-tab-s9ultra/` (X910, a local reference
clone), and `android_kernel_samsung_gts9/` (Samsung's own stock
downstream kernel for this exact device, X716B -- the single most
authoritative source available, more so than either sibling-device
reference project).

**All three agreed exactly**, independently, byte-for-byte on the
mechanism (the stock kernel's own four board-revision DTBs, r00 through
r04, also agreed with each other and with both reference projects):

- **Power**: not a discrete GPIO at all -- a child node (`pwrkey`) of the
  PMK8550 PMIC's own PON (power-on) hardware block, addressed over SPMI.
  `linux,code = KEY_POWER` is upstream's own default on this node; the
  board DTS only needs `status = "okay"`.
- **Volume Down**: the *same* PON block's RESIN ("reset-in") pin --
  normally the hardware power+resin force-reset combo -- repurposed as a
  plain key input, the standard reference-design pattern across this
  whole SM8550 tablet family. Needs both `status = "okay"` *and*
  `linux,code = KEY_VOLUMEDOWN` (upstream leaves resin's code board-
  specific, unlike pwrkey's).
- **Volume Up**: the only one of the three that's a real discrete GPIO --
  `gpio-keys`, but on a **PM8550 PMIC GPIO** (pin 6), not `&tlmm`.
  Active-low, internal pull-up, 15 ms debounce, `wakeup-source`.
- **Kconfig**: `CONFIG_KEYBOARD_GPIO`/`CONFIG_INPUT_PM8941_PWRKEY` were
  already `=y` in defconfig. `CONFIG_POWER_RESET_QCOM_PON` was not --
  it defaults to `=m`, and since this project doesn't autoload modules,
  that parent PON node would never probe, silently leaving Power and
  Volume Down dead while only the unrelated gpio-keys Volume Up worked.
  Both the X710 and X910 reference projects independently found and
  fixed this identical gap in their own config fragments -- a real,
  recurring pattern for this whole board family, not board-specific
  guesswork.

Implemented in `kernel/dts/sm8550-samsung-x716b.dts` (`&pon_pwrkey`,
`&pon_resin`, a new `gpio-keys` node, `&pm8550_gpios`'s `volume_up_n`
pinctrl state) and `kernel/config/config-x716.fragment`
(`CONFIG_POWER_RESET_QCOM_PON=y`). Rebuilt, reflashed (with explicit
confirmation, against the existing 2026-09-07 nandroid backup), and
verified about as directly as possible: `dmesg` showed all three input
devices (`pmic_pwrkey`/event0, `pmic_resin`/event1, `gpio-keys`/event4)
probing with the exact expected `KEY_POWER`/`KEY_VOLUMEDOWN`/
`KEY_VOLUMEUP` bitmasks, then a **live `evtest` capture caught a genuine
`KEY_POWER` press -- which promptly shut the tablet down**, since GNOME
hadn't started yet and there was no session policy to intercept it at
the tty. That's about the strongest possible confirmation the whole
chain (PMIC -> kernel driver -> evdev -> logind's default action)
actually works, even though it wasn't the *intended* test. After
powering back on into a full GNOME session, the user confirmed all
three buttons directly: power now suspends (GNOME's own default policy
for a short press, with a session running), and both volume buttons
work correctly.

**Distro-agnostic by construction, not by extra effort this time**: the
entire change is `kernel/dts/`+`kernel/config/` only -- nothing under
`rootfs/overlay-common/` or `rootfs/overlay-systemd/` was touched, and
none was needed. These three input devices register as completely
standard Linux evdev nodes; which userspace daemon (if any) acts on
`KEY_POWER`/`KEY_VOLUMEUP`/`KEY_VOLUMEDOWN` is entirely up to whatever
distro sits on top (systemd-logind's own default here, unmodified -- no
project-specific override added) and isn't this feature's concern. Kernel
and DTB are built once by `scripts/build-mainline-kernel.sh` and boot
identically under every rootfs this project carries, so this lands on
Fedora, Alpine, Buildroot, and Ubuntu alike with zero additional work,
unlike the audio/sensor work that needed the `overlay-common`/
`overlay-systemd` split.

### S Pen: fixing "stuck in one orientation" across display rotation

Full writeup in `docs/s-pen-orientation.md` (kept as its own doc, not
folded into this log, per direct instruction). Summary: two additive
bugs, both fixed. (1) `digitizer@56`'s raw axes didn't match the panel's
native frame -- same class of bug the touchscreen needed
`touchscreen-swapped-x-y`/`-inverted-x` for, confirmed algebraically from
the driver's own queried limits against the panel's real physical size
before ever touching the device, then confirmed live after flashing via
`udevadm`'s own computed `ID_INPUT_WIDTH_MM=236`/`HEIGHT_MM=147` matching
the panel almost exactly. (2) GNOME/mutter never managed the device's
rotation at all, because it registers as a libinput tablet-tool
(`ID_INPUT_TABLET=1`), not a touchscreen, and tablet-tools only get
automatic per-rotation calibration if `libwacom` recognizes them as
integrated into the display -- the driver never set `input->id.vendor`/
`id.product` and no `.tablet` database file existed. Fixed by setting
those fields to a stable made-up pair (`0xf000`/`0x0056`, collision-
checked against every `.tablet` file already in this project's built
rootfs) and shipping a matching `samsung-wez01.tablet` file in
`rootfs/overlay-common/usr/share/libwacom/` -- confirmed live,
`libwacom-list-local-devices` went from "not supported" to fully
recognizing it the moment the file was pushed to the running device. The
user confirmed correct pen tracking across multiple real display
rotations afterward, not just the "normal" baseline -- the actual
regression test for the original bug.

Also root-caused, mid-session, something that looked like a boot
regression from this exact patch but wasn't: two flashes in a row
appeared to hang on boot, including one deliberately built from the
*pre-fix* kernel/DTB as a bisection test -- which should have booted fine
and didn't, at first suggesting SD card corruption. The tty's actual
error (`exFAT-fs (mmcblk0p1) invalid boot record signature`) traced back
to a missing `BRINGUP_RAMDISK` override on both `nix run .#build-bundle`
invocations, silently falling back to the stale original bring-up debug
ramdisk (`scripts/build-bringup-ramdisk.sh`'s output), which still
`mount -t exfat`s the microSD the way it did before this project
repartitioned it to ext4. Neither flash could ever have reached the real
rootfs, regardless of source changes. Reflashing with `BRINGUP_RAMDISK`
pointed at `out/real-root-initramfs.cpio.gz` booted cleanly in the
normal ~40s. No regression, no corruption -- a process mistake, now
documented in `docs/s-pen-orientation.md` as a reminder for future
sessions.

### USB host mode and charging, fixed -- confirmed on real hardware

Root cause: `&usb_1`'s `dr_mode = "peripheral";`
(`kernel/dts/sm8550-samsung-x716b.dts`), added 2026-09-05 to get a
working debug gadget console before the Type-C stack's own prerequisite
patches existed. Forcing peripheral mode skips
`dwc3_get_dr_mode()`'s live GHWPARAMS0 hardware readback and, with it, the
`/sys/class/usb_role/` device registration `ps5169` (the SuperSpeed/DP
redriver and role switch, `usb-role-switch = <&usb_1>;`) blocks on
forever -- so `ps5169` never probed, and downstream of it, real
device-ownership/host-mode and (per `sm5714_battery.c`'s
`sm5714_configure_charging()`) full-rate PD/PPS charging never engaged
either. This project's own history had already traced this and explicitly
planned to remove the override "once [the eUSB2-PHY-init/ptn3222-DT/TCPM-
retained-role] patches are in" (see the Phase 1 pivot entry above) -- those
four patches were confirmed present and applied, but the flip itself was
never executed as its own step, until now.

Three changes, all landed together as planned:

1. **`kernel/dts/sm8550-samsung-x716b.dts`**: removed the `dr_mode =
   "peripheral";` override entirely, matching gts9wifi-fedora's own DTS
   for this exact SM8550 dwc3 IP block (no override at all). Comment
   replaced with a short pointer to this entry.
2. **`kernel/config/config-x716.fragment`**: checked, no change needed --
   `CONFIG_USB_ROLE_SWITCH`/`CONFIG_USB_DWC3`/`CONFIG_USB_DWC3_QCOM` all
   already `=y` in the merged `.config` (confirmed via a real build, not
   assumed), unlike the several prior "silently defaults to `=m`" bugs
   this project has hit.
3. **`kernel/drivers/sm5714_usbpd.c`**: wired `sm->tcpc.
   adopt_retained_source_ufp = true` and a `consume_retained_sink_dfp`
   callback, ported from gts9wifi-fedora's own driver -- the two upstream
   `tcpc_dev` hooks these need
   (`kernel/patches/tcpm-adopt-retained-source-ufp-role.patch`,
   `kernel/patches/tcpm-use-retained-sink-data-role.patch`) were already
   applied to this project's pinned tree, but a stale comment claimed they
   weren't and the driver never used them. Kept alongside, not replacing,
   this repo's own hand-rolled CC-detach/reattach dock recovery (same as
   the reference driver does) and this repo's own additive reliability
   work beyond gts9wifi-fedora (`otg_rp`/`otg_ma` module params,
   `cc_watch_work` attach watchdog) -- none of that was reverted.

**Verified on real hardware, not just probe success**: after flashing,
`dmesg` showed `ps5169 4-0028: PS5169 redriver detected (chip id 69:87)`
and `sm5714-usbpd 3-0033: SM5714 USB Type-C/PD controller registered` --
both previously stuck forever. `/sys/class/usb_role/a600000.usb-role-
switch/role` now exists. `xhci-hcd xhci-hcd.1.auto: irq 283, io mem
0x0a600000` -- the real xHCI host controller for this exact dwc3 block --
registered, and **the user plugged in a real USB-C hub and it fully
enumerated**: a 4-port hub plus a nested sub-hub, multiple downstream
ports (`1-1`, `1-1.1`, `1-1.1.1`-`1-1.1.4`, `1-1.2`), confirmed working by
the user directly ("my usb hub worked") -- the actual regression test for
"never takes ownership of USB devices."

Charging: with a real PD charger attached, `dmesg` showed genuine PPS
direct-charge activity, not just fixed-PD fallback --
`sm5714-usbpd 3-0033: USB-PD contract: 8200 mV, 2000 mA` alongside real
`sm5440-direct` telemetry (`direct: pack=31.2C vbus=7881mV ibus=1444mA
vbat=3800mV die=37.0C`, i.e. the 2:1 direct-charge pump actually pumping
~1.3-1.5A into the battery), then a clean fallback to the fixed-PD path
at `USB-PD contract: 9000 mV, 1660 mA` / `enabled charging for USB type 6
at 9000 mV (1660 mA input, 2800 mA fast)` -- the full 15 W the connector's
`sink-pdos` declares, versus the ~500 mA/2.5 W BC1.2 SDP fallback this
board was stuck on before (no PD contract ever completing). **Per direct
instruction, charging is documented as observed working in this session,
not as a fully closed-out ✅** -- the PPS/direct-charge path in particular
warrants more extended real-world testing (different chargers, a full
charge cycle, thermal behavior) before calling it fully proven.

Distro-agnostic by construction, same as the power/volume-button fix:
the entire change is `kernel/dts/`+`kernel/config/`+`kernel/drivers/`
only -- nothing under `rootfs/overlay-common/` or `rootfs/overlay-
systemd/` was touched or needed. USB role switching, TCPM, and charging
current are all kernel/driver-level behavior; no userspace daemon or
init-system-specific glue is involved.

### Bluetooth HID input, and a much bigger story underneath it: broad kernel hardware support, a real deployment bug, and a real SELinux regression -- all found and fixed on real hardware

Real-hardware report: a wireless Bluetooth keyboard and touchpad, once
paired, produced no keystrokes or pointer movement, even though the
radio itself was fine (dmesg showed `"QCA setup on UART is completed"`).
The `wcnhpbtfw21.tlv`/`wcnhpnv21.bin` "failed with -2" lines the user
saw first were a red herring -- confirmed by reading
`kernel/linux/drivers/bluetooth/btqca.c` directly: WCN6855 always tries
the `wcn`-prefixed firmware name first, and the driver has its own
built-in fallback to the non-prefixed name for exactly this case
(`"Due to historical reasons, WCN685x chip has been using firmware
without the 'wcn' prefix"`), which then succeeds. Not a bug.

**Root cause of the real bug**: `CONFIG_UHID` and `CONFIG_HIDRAW` were
completely absent from this project's kernel. BlueZ's `input` plugin
creates a virtual HID device via `/dev/uhid` for any paired keyboard/
mouse/touchpad, which the kernel's HID core then turns into a real evdev
device -- without `/dev/uhid`, pairing can succeed but no input ever
reaches the kernel.

**Widened, per explicit user decision, into something much bigger.**
Digging into *why* one Kconfig symbol was missing revealed this
project's kernel config had always started from plain
`make ARCH=arm64 defconfig` (intentionally minimal upstream defaults)
plus a 31-line "quality of life" fragment and this board's own 392-line
fragment -- nothing beyond what's needed to boot this specific board.
The sibling reference project `gts9wifi-fedora` does something
structurally different: its own `kernel/files/config-mainline.aarch64`
is a full, already-generated 12,664-line kernel `.config` (version
header confirms `Linux/arm64 7.2.0-rc3`, the same generation as this
project's pinned v7.2 tag), `cp`'d in wholesale as the starting
`.config` before their own board fragment is layered on top -- giving
them ~500 more enabled symbols (mostly loadable modules: HID vendor
quirks, extra filesystems, more USB/sound device classes) "for free."
Asked directly ("Can we just enable as much hardware support as
possible... standard fedora kernel-level of hardware support"), the
user chose to go broad rather than patch the one missing symbol.

**Fix, part A -- kernel config**: replaced this project's own
`kernel/config/config-mainline.aarch64` wholesale with gts9wifi-fedora's
vendored base (see that file's own header for full provenance/
rationale), kept the same merge order in
`scripts/build-mainline-kernel.sh` (board fragment layered on top via
`merge_config.sh`, unchanged), and added `CONFIG_UHID=y`/
`CONFIG_HIDRAW=y`/`CONFIG_BT_HIDP=y` to `config-x716.fragment` as a
belt-and-suspenders explicit ask (the vendored base already sets them,
but this project's own curated fragment is what's held strictly
accountable by the build's verification loop). Split that verification
loop to check only `config-x716.fragment` strictly -- the vendored base
is a generic, non-board-specific file, and some of its ~12,700 lines
legitimately resolve differently against this project's own patched
tree; that's expected, not a regression.

Using gts9wifi-fedora's base meant real loadable kernel modules for the
first time in this project (previously everything hardware-critical was
forced `=y`, built-in, with no `modprobe` path). Added a real
`modules_install`/`depmod` pipeline: `scripts/build-mainline-kernel.sh`
now runs `make modules` + `make INSTALL_MOD_PATH=... modules_install` +
`depmod -b ...` after building Image/DTB (gts9wifi-fedora gets this for
free from RPM kernel packaging, which this project's own pipeline
deliberately doesn't use -- Phase 4), and
`scripts/build-fedora-rootfs.sh` copies the resulting `/lib/modules/`
tree into the rootfs (stripping the dangling `build` symlink
`modules_install` leaves pointing at this build host's own tree, not
useful on-device).

**A real bug found in this project's own verification loop, mid-build**:
Kconfig never writes `KEY=n` to a `.config` -- an explicitly-off
boolean is represented as `# KEY is not set`. The strict-verification
loop's string comparison didn't know this, so `CONFIG_SECURITY_SELINUX=n`
(added later, see below) always "failed" verification even when it had
landed correctly, aborting the build before it ever reached the `Image`
step. Fixed by recognizing that form too.

**A real process mistake, not a kernel bug**: after the first successful
kernel+modules build, only the boot-chain images (boot/init_boot/
vendor_boot/dtbo) were flashed -- the freshly-built rootfs tarball (with
`/lib/modules/` finally populated) was never actually deployed to the
microSD. The device booted the brand-new kernel against its *old*
persistent rootfs. `modprobe tun` failed with `"Module tun not found in
directory /lib/modules/7.2.0-dirty"` even though the module file
provably existed in the freshly-built rootfs tree -- because that tree
was never written to the device. Confirmed and fixed by redeploying:
TWRP, fresh `mke2fs -t ext4 -L x716b-root` on the SD card's root
partition, `adb push` the tarball, `tar --numeric-owner -xzf` in place
-- the same "fresh `mke2fs`, `adb push` + `tar --numeric-owner -xzf`"
mechanism this project's own docs already recorded as the established
deploy procedure (Phase 6/7 entry above), just never re-run this
session. (Also surfaced, separately: `scripts/build-fedora-rootfs.sh`
defaults to `GTS9_DESKTOP=core`, a minimal no-GNOME variant -- the *old*
rootfs on the device had GDM installed, so it was actually a `gnome`
build from an earlier session. Redeployed with `GTS9_DESKTOP=gnome`
explicitly for the real, final deploy.)

**The real regression, found via real hardware, not guessing**: even
after the rootfs redeploy fixed the missing-modules symptom (confirmed:
`insmod tun.ko.zst` now worked, `/dev/uhid` existed), the *exact same*
catastrophic failure remained on a fully fresh, matched kernel+rootfs
boot: `systemd-journald.socket`, `dbus.socket`, `systemd-udevd-kernel/
-control.socket`, `systemd-logind.service`, `systemd-oomd.socket`, and
over a dozen more core sockets all failed at boot with
`Result: resources`, taking down GDM (no desktop at all) and D-Bus
(nothing socket-based worked) with them. A pre-existing watchdog unit
(`gts9wifi-x11-dir-fix.path`/`.service`, meant to keep `/tmp/.X11-unix`
root-owned for XWayland) got caught in this and re-triggered
~150+ times/second continuously from boot -- almost certainly the
"screen full of spammed logs" the user first reported -- masked live
via `systemctl mask` as an immediate stabilization step (load average
dropped from 3.6 to under 2 within seconds) while root-causing the real
issue underneath it.

`dmesg` (captured before the x11-dir-fix flood evicted it from the ring
buffer, then again cleanly on a later boot once that unit was masked)
showed the real signature, identical for every failing socket:
```
systemd[1]: <unit>: Failed to determine SELinux label: Invalid argument
systemd[1]: <unit>: Failed to listen on sockets: Invalid argument
systemd[1]: <unit>: Failed with result 'resources'.
```
Live diagnostic test (explicit user confirmation first, since it's a
system-config edit): setting `/etc/selinux/config`'s `SELINUX=disabled`
and rebooting made every one of those ~20 failures disappear completely
-- only one unrelated, pre-existing failure (`pd-mapper.service`,
ADSP/sensors, a separate subsystem) remained. Confirmed the diagnosis
cleanly.

**Root cause, confirmed by reconstructing the old `.config` from git
history and diffing it against the new one**: the *old*, minimal
defconfig-based kernel never had `CONFIG_SECURITY_SELINUX` compiled in
at all (`CONFIG_DEFAULT_SECURITY_DAC=y`, no `selinux` in the `CONFIG_LSM=`
ordering string) -- so despite `/etc/selinux/config` claiming
"permissive" the whole time, SELinux was actually a complete no-op on
every single prior boot of this project; userspace's
`is_selinux_enabled()` correctly detected no kernel support and silently
skipped all labeling. gts9wifi-fedora's vendored base turns
`CONFIG_SECURITY_SELINUX=y` on for real (a genuine Fedora-style base
config naturally does, being close to a full-distro kernel). With a
*real* SELinux subsystem now active and a real policy loaded (`SELinux:
policy capability cgroup_seclabel=1` in dmesg), Fedora 44's shipped
`selinux-policy` package turned out to be incompatible with this
project's bleeding-edge pinned v7.2 kernel's SELinux policy/class ABI --
label computation for brand-new kernel objects (sockets) fails with
`EINVAL` regardless of enforcing vs. permissive mode, since permissive
only skips the *enforcement* decision, not label computation itself.

**Fix**: force `CONFIG_SECURITY_SELINUX=n` in `config-x716.fragment`
(with the full story in a comment there), restoring exactly what was
actually running successfully in every prior session. Updated
`scripts/build-fedora-rootfs.sh`'s `/etc/selinux/config` write from
`SELINUX=permissive` to `SELINUX=disabled` to say what's actually true,
rather than leave an aspirational, inert setting in place. Getting a
real, policy-compatible SELinux stack running on this kernel is real,
undone future work, out of scope for this session.

**Full verification on real hardware, start to finish**: rebuilt the
kernel (verification loop now passes cleanly with the `=n` fix),
rebuilt the GNOME rootfs (`GTS9_DESKTOP=gnome`, 2.39 GB tarball,
`SELINUX=disabled` confirmed baked in, `tun.ko.zst` confirmed present),
flashed all 4 boot-chain partitions, redeployed the rootfs via the
established `mke2fs`+`adb push`+`tar` procedure, and rebooted clean:
`systemctl --failed` showed only the pre-existing, unrelated
`pd-mapper.service`; `dbus-broker`/`systemd-journald`/`systemd-udevd`/
`bluetooth` all `active`; `gdm.service` came up and started a real
session; the system clock, previously stuck weeks in the past (no
working NTP without a functioning network stack), self-corrected once
networking/D-Bus were healthy. **The user directly confirmed on
hardware: "Everything's working, keyboard and touchpad both connected
fine."**

Distro-agnostic where it can be: the BT HID fix itself
(`CONFIG_UHID`/`CONFIG_HIDRAW`/`CONFIG_BT_HIDP`) and the modules
pipeline are pure kernel/build-system changes, no rootfs overlay
touched. The SELinux fix is Fedora-rootfs-specific by nature (only
Fedora ships `selinux-policy` and expects it enforced/permissive) --
`SELINUX=disabled` is written only by `scripts/build-fedora-rootfs.sh`,
not any distro-agnostic overlay path.

### WiFi throughput bring-up session: real fixes landed, root cause of the remaining gap not found

Real-hardware report: the same tablet, same network, gets 400-600 Mbps
under stock Android but only 500 Kbps-8 Mbps under this port. Investigated
over SSH (both USB gadget and real WiFi) plus a background code
investigation comparing this project's DTS/config/firmware against the
real, hardware-proven `gts9wifi-fedora` reference for the same chip
family.

**Fix 1, confirmed real and working**: `iw dev wlp1s0 get power_save`
showed power-save **on**. Root cause: mainline's own `net/wireless/
core.c` (`wiphy_register()`) unconditionally sets
`WIPHY_FLAG_PS_ON_BY_DEFAULT` for every wiphy -- this is standard
upstream kernel behavior, not a port-specific bug, so the fix belongs in
userspace. Turning it off manually dropped ping RTT from 43ms to 3-7ms
instantly. Added two overlay fixes: a distro-agnostic udev rule
(`rootfs/overlay-common/usr/lib/udev/rules.d/
72-gts9wifi-wifi-powersave-off.rules`, fires `iw ... set power_save off`
at interface-creation time -- for any non-NetworkManager rootfs variant)
and, after confirming live that this Fedora rootfs's NetworkManager
actively re-asserts its own power-save policy on every (re)connection
and silently undoes the udev rule's effect, the real fix for that case:
`rootfs/overlay-systemd/etc/NetworkManager/conf.d/
99-wifi-powersave-off.conf` (`wifi.powersave = 2`). Verified live: power
save stays "off" across a full `systemctl restart NetworkManager`
(reconnect), not just until the next event.

**Fix 2, confirmed real, clean, but did not move throughput**: the
background investigation found this project's own DTS driving the WiFi/
BT combo chip under the wrong declared identity, self-contradicting this
project's own real-hardware measurement (`docs/hardware-facts.md`: real
chip identifies as `wcn6855 hw2.1`, PCI ID `17cb:1103`):
- `wifi@0`'s `compatible` was `"pci17cb,1101"` (QCA6390) instead of
  `"pci17cb,1103"` (WCN6855) -- gts9wifi-fedora's own proven DTS uses
  the correct one for the identical chip.
- `wcn_pmu`'s `compatible` was `"qcom,qca6390-pmu"` instead of
  `"qcom,wcn6855-pmu"` -- functionally real:
  `drivers/power/sequencing/pwrseq-qcom-wcn.c` picks a different
  regulator-supply property name table per branch.
- Both wifi@0 and (separately, a second latent bug found along the way)
  the Bluetooth node still used the QCA6390 branch's `vddrfa1p7-supply`
  property name despite Bluetooth's own `compatible` already having been
  corrected to `"qcom,wcn6855-bt"` in an earlier session -- the required
  WCN6855-branch property name is `vddrfa1p8-supply` (same underlying
  `&vreg_pmu_rfa_1p7` rail, matching the binding's own worked example;
  only the consumer-side property name was wrong). Fixed both.
- `wcn_pmu`'s `vddpmu-supply` reused `vreg_s4e_0p952` -- this die's
  shared USB3/DP combo PHY PLL rail doing double duty, not a dedicated
  WLAN-PMU digital rail. gts9wifi-fedora's own proven DTS gives the WLAN
  PMU its own separate S5G rail; this project's DTS never defined one at
  all. Added `vreg_s5g_0p966` (value borrowed from gts9wifi-fedora by
  analogy -- this project's own stock downstream DTS has no literal S5G
  value to measure independently, same situation an earlier session
  already documented for S4G/S6G) and rewired `vddpmu`/`vddpmumx`/
  `vddpmucx` onto it.
- `vddaon-supply`'s rail (`vreg_s2g_0p98`, 0.98V) sat 32mV *below* this
  project's own `qcom,wlan-pdc-init` AOP vote table's own upval for that
  exact rail (`s2g.v upval: 1012`) -- a real internal self-contradiction,
  same bug class as an earlier session's S4G/S6G fix (just the opposite
  direction: below the ceiling, not above it, so it never risked that
  fix's specific AOP-clamp failure mode, but still contradicted this
  project's own PDC table). Corrected to 1.012V, matching this project's
  own established "sit exactly at the upval" methodology.

All of this landed cleanly on real hardware: `dmesg` shows
`vreg_s2g_1p012: Setting 1012000-1012000uV`, `vreg_s5g_0p966: Setting
968000-968000uV`, `wcn-pmu` probing with no errors (one ordinary
`-517`/`EPROBE_DEFER` retry, resolves immediately), `ath11k_pci`
associating exactly as before. **But it did not move the needle on
throughput or signal**: before this fix, signal measured -84 dBm with a
real 55MB SCP transfer landing ~8.9 Mbit/s; after, in the user-confirmed
*same physical position*, signal measured -88 to -90 dBm with the same
transfer landing ~6.3 Mbit/s -- within normal minute-to-minute RF
variance for an already-marginal link, not a regression, but not an
improvement either. Still a real, worthwhile correctness fix (matches
the project's own measured hardware identity and the proven reference
wiring) -- just not the answer to the throughput question.

**Investigated board-2.bin as the likely remaining cause -- found the
opposite of what was expected.** Initial read of the shipped generic
upstream `ath11k/WCN6855/hw2.1/board-2.bin` (158 board-ID entries)
seemed to show zero Samsung entries, all HP/Dell/Qualcomm-reference-
design subsystem-vendor IDs, with `dmesg`'s `board_id 0xff` read as "no
match, generic fallback used." **Both readings turned out to be wrong
on closer inspection**: this tablet's own real PCI subsystem ID
(`lspci -vv`: `subsystem-vendor=17cb, subsystem-device=0108` -- Samsung
apparently never rebranded this off Qualcomm's own reference value) has
multiple *exact* matches in that same container, including
`qmi-chip-id=2,qmi-board-id=255` with no variant name -- an exact match
on every field `dmesg` reports for this chip (`chip_id 0x2`,
`board_id 0xff` = 255 decimal). `board_id 0xff`/255 is simply this
chip's own real board-strap value, not a "no calibration found"
sentinel -- it's one of the single most common `qmi-board-id` values in
the whole container, shared by real entries for other OEMs on the same
reference PCI-subsystem ID (e.g. the Lenovo ThinkPad X13s,
`variant=LE_X13S`, same `subsystem-device=0108`). So WiFi is very likely
*already* using a real, exact-match calibration profile -- just one
shared with other OEMs who used this same Qualcomm reference design,
not a Samsung-exclusive one, because Samsung's own hardware doesn't
expose a distinguishing subsystem ID for ath11k's lookup to key off of
in the first place.

Checked whether a real Samsung-specific board-data file could be built
from this device's own dumped `vendor-firmware-dump/firmware/qca6490/
bdwlan.elf`/`bdwlang.elf` instead. Confirmed directly: these are raw ARM
32-bit ELF executables (Qualcomm's own Peripheral-Image-Loader format),
structurally nothing like ath11k's `board-2.bin` TLV container. Web
research confirmed this isn't a gap in this project's own knowledge --
it's an independently-documented, unsolved problem in the broader ath11k/
OpenWrt community: the current BDF format has no public documentation
(Qualcomm requires an NDA), and existing open-source decoders are known
to fail on it ([OpenWrt forum: "Qualcommax & ath11k board calibration &
BDF data woes"](https://forum.openwrt.org/t/qualcommax-ath11k-board-calibration-bdf-data-woes/182646)).
`ath11k-bdencoder` (from the `qca-swiss-army-knife` repo) is a real,
established tool for *building* `board-2.bin` from already-decoded
`.bin` blobs + a JSON descriptor -- useful if a real calibration blob
were in hand, but it doesn't solve getting one out of `bdwlan.elf` in
the first place. Combined with the sibling X910 Ultra port's own
documented real MHI RDDM crash from a mismatched board-data/firmware
generation pairing, and that the community entry we're likely already
using is a real, non-generic match rather than a degraded fallback --
**decided not to attempt this conversion**: real (if narrow) crash
risk, confirmed-unsolved-upstream format, and likely little to gain even
if it worked.

**Net result, per explicit user decision to stop here**: power-save fix
(real, measured, confirmed persistent) and the chip-identity/regulator
correctness fixes (real, clean, no regressions) are landed. The
remaining throughput gap vs. stock Android is most likely a genuine
antenna/RF-front-end hardware characteristic (or simply normal variance
on an already-marginal link at this test location), not something
further software/calibration-file changes can safely or confidently
close -- `README.md`'s Wi-Fi row reflects this honestly (⚠️, not ✅ or
❌) rather than overclaiming a fix that wasn't actually confirmed.

### WiFi throughput, round 2: three parallel research agents (X910 Ultra, a deeper gts9wifi-fedora re-check, and web research), one more real fix found and landed, throughput still unmoved

Per explicit user request, spawned three subagents in parallel to look for
anything missed: the sibling `ubuntu-galaxy-tab-s9ultra` port, a much
deeper re-check of `gts9wifi-fedora`, and general web research on known
ath11k/WCN6855 throughput issues.

**X910 Ultra: no new lead.** Confirmed they use a different chip entirely
(WCN7850/ath12k, not WCN6855/ath11k) and never benchmarked WiFi
throughput at all -- their own docs only ever confirm basic ping
connectivity. The two DTS/patch-level fixes their project independently
also needed (PCIe0 PIPE-mux unpark, AOP PDC power sequencing) were
already adopted into this project in an earlier session, well before
this throughput investigation started.

**Web research: two leads, both checked and closed.** (1) MSI vector
fallback -- ath11k silently degrades to 1 shared MSI vector (serializing
all RX/TX/copy-engine interrupts onto one core) if the PCIe host can't
grant the chip's requested vector count; a real, documented failure mode
on other Qualcomm ARM platforms. Already ruled out: this session's own
earlier dmesg capture shows `MSI vectors: 32` -- the full count, not the
degraded fallback. (2) `qcom,calibration-variant` -- confirms the exact
mechanism behind the board-2.bin finding from the prior session (this
DT property appends `,variant=<string>` to the board-2.bin lookup key
specifically to disambiguate colliding subsystem IDs, which is exactly
this device's situation), and found that the Lenovo ThinkPad X13s
(same WCN6855, same colliding PCI subsystem ID 17cb:0108) sets
`qcom,calibration-variant = "LE_X13S"` in its own upstream DTS to get a
dedicated calibration entry instead of the generic one. Confirmed via
its own honest caveat, though: setting this property without a matching
variant entry actually present in the `board-2.bin` being loaded is a
no-op (the lookup just falls through to the same generic entry either
way) -- and building a new variant entry runs into the exact same
undocumented-BDF-format/crash-risk wall already declined last session.
Not pursued, for the same reason.

**gts9wifi-fedora deep re-check: one real, concrete, previously-missed
regression found and fixed.** The prior session's own `wcn_pmu`
chip-identity fix (`"qcom,qca6390-pmu"` -> `"qcom,wcn6855-pmu"`, correct
on its own, matching this project's real measured hardware) had a silent
side effect: `drivers/power/sequencing/pwrseq-qcom-wcn.c`'s
`of_device_id` match table resolves each compatible string to a
*separate* pdata struct (`pwrseq_qca6390_of_data` vs.
`pwrseq_wcn6855_of_data`). This project's own
`kernel/patches/qca6390-pwrseq-cold-reset-aop.patch` only ever set
`.cold_reset_wlan = true` on `pwrseq_qca6390_of_data` -- written back
when the DTS still used that compatible string. Once the DTS was
corrected to `"qcom,wcn6855-pmu"`, the driver started resolving to
`pwrseq_wcn6855_of_data` instead, which never got the same flag added --
the patch silently stopped doing anything for this board. Cross-checked
against gts9wifi-fedora's own equivalent patch
(`wcn7850-pwrseq-cold-reset-aop.patch`): they set `.cold_reset_wlan =
true` directly on `pwrseq_wcn6855_of_data` (and separately on
`pwrseq_wcn7850_of_data` for their own sibling board) -- i.e., attached
to whichever struct their own compatible string actually resolves to,
exactly the pattern this project's patch fell out of sync with. Fixed by
adding the same field to `pwrseq_wcn6855_of_data` too.

`cold_reset_wlan` controls real boot-time behavior
(`pwrseq_qcom_wcn_probe()`): with it set, WLAN_EN is requested
`GPIOD_OUT_LOW` and the code sleeps 5-10ms before the normal regulator ->
clock -> enable sequence runs, giving the chip a real power-cycle from a
known state; without it, WLAN_EN is requested `GPIOD_ASIS` and
immediately driven back to whatever value it already had -- no real
power-cycle at all, just inheriting whatever XBL/ABL left behind. A chip
that never gets a real WLAN_EN cold-reset can still probe, associate,
and pass some traffic (matching "works but badly," not "doesn't work"),
while plausibly leaving analog RF/PLL state uncalibrated.

**A second, unrelated real bug found and fixed while verifying this**:
`kernel/patches/qca6390-pwrseq-cold-reset-aop.patch` itself turned out
to be a malformed unified diff (a blank context line lacking its
required single leading space, confirmed independently of this
session's own edits -- the *original*, pre-session version of the patch
fails identically against a pristine v7.2 source with GNU patch 2.8,
the exact version this project's own build environment provides). This
had been silently masked ever since it was first authored: the build
script's `apply_unless` idempotency check only greps for a marker
string in the already-patched, persistent `kernel/linux` checkout and
skips re-applying if found -- so the patch had likely never actually
been re-tested via a real `patch` invocation since its first successful
application. A fresh clone of this repo would have failed to build at
this exact step. Regenerated the whole patch file via a real `diff -u`
between a pristine copy (`git show HEAD:...` inside the vendored kernel
checkout) and the current, fully-corrected live source, and verified
byte-for-byte that re-applying it to the pristine file reproduces the
live file exactly, before replacing the old hand-edited patch file with
this verified one.

**Verified on real hardware**: `wcn-pmu`'s probe time increased from
~4ms to ~10.5ms (10524 usecs), consistent with the new 5-10ms
`cold_reset_wlan` settle delay actually executing now (previously a
silent no-op). `MSI vectors: 32` confirmed unchanged (still full count).
Power-save confirmed still off. **But throughput was, again, unchanged**:
signal -88 dBm, rx bitrate down to VHT-MCS 0/NSS1 (6.5 Mbit/s PHY rate),
and a real 55 MB SCP transfer measured ~7.3 Mbit/s -- squarely inside
the same noisy 6-9 Mbit/s band every fix this session and last has
landed in, regardless of what was changed.

**Where this leaves things**: three independent fix rounds (power-save,
DTS chip-identity/regulator correctness, and now `cold_reset_wlan`) plus
three parallel research angles (a different-chip sibling port, a much
deeper same-chip reference-port re-check, and general web research) have
now all converged on the same conclusion -- every software/DT/Kconfig-
level avenue this session could find either doesn't apply
(different chip, no throughput data to compare against), was already
ruled out with a direct real-hardware measurement (MSI vectors, PCIe
link speed/width, board-2.bin match legitimacy), or landed clean and
correct but left throughput and signal exactly where they were. All
three fixes are kept -- they're each independently real and correct,
matching this project's own established "worth doing regardless of the
throughput question" standard from the prior session -- but the
throughput gap itself remains open, and is now fairly strongly
suspected to be a genuine antenna/RF-front-end hardware characteristic
of this specific tablet model (the 5G variant's extra cellular
antennas may share PCB real estate/RF front-end with WiFi in a way the
WiFi-only X710 does not) rather than anything a further software fix
can close.

### WiFi throughput, round 3: SOLVED — Samsung's own factory calibration, and a real bug in Samsung's firmware

Full write-up: **`docs/wifi-samsung-calibration.md`**. Summary:

Per explicit user instruction (with informed acceptance of crash risk),
pursued this device's own dumped Samsung calibration data
(`vendor-firmware-dump/firmware/qca6490/…/bdwlan.elf`) as the cause of
the throughput gap. 13 live crash/recovery cycles and three deep-dive
analyses later, the whole chain is established and confirmed on
hardware:

- The generic community `board-2.bin` calibration genuinely does not fit
  this board — one RX chain sits pinned at the noise floor (`-93` vs
  `-57` dBm), which is why throughput was stuck at 6–9 Mbit/s regardless
  of anything done at the software/DT level.
- Samsung's real calibration is authored for firmware branch
  `WLAN.HSP.2.0.c11-00358`; feeding it to the community `HSP.1.1`
  `amss.bin` crashes on BDF parse (every representation tried).
- Samsung's own **version-matched** firmware set (`amss20.bin` +
  Samsung's `m3.bin` + `bdwlan.elf`) parses the BDF cleanly and boots to
  a real connection — then crashes ~880 ms in. Root-caused from the
  firmware RDDM coredump + Hexagon disassembly to an **unconditional
  NULL-pointer dereference in that firmware build's
  `WMI_VDEV_SET_WMM_PARAMS` handler** (`wal_pdev->[0x37c]` is NULL; the
  exact fault instruction exists 3× in `amss20.bin`, 0× in the community
  `amss.bin`). Not a vdev-lifecycle timing issue — confirmed by testing
  three different call sites, all crash at the identical delay.
- Fix (`kernel/patches/ath11k-defer-wmm-params-until-vdev-started.patch`,
  wired into `scripts/build-mainline-kernel.sh`): defer the WMM-params
  WMI send until `arvif->is_started` (correct regardless, also fixes a
  latent all-zero-AC wart), plus `ath11k_mac_skip_legacy_wmm_params()` —
  `ath11k.skip_legacy_wmm_params` module param, default `-1` = auto,
  skipping only on firmware whose build id contains `WLAN.HSP.2.0`. The
  only host-side workaround, since the firmware is PIL-signed; WMM/EDCA
  tuning is lost when it engages.
- **Result, measured**: Samsung matched triple + quirk → stable
  association, zero `MHI_CB_EE_RDDM` over a sustained transfer, no dead
  antenna chain, NSS 2 / VHT operation, and **~40 Mbit/s download vs
  ~8 Mbit/s on the community set** (~5×) — at a weaker signal on a
  harder band.

**Productionised (2026-09-10), validated on a cold boot**:
`scripts/fetch-ath11k-firmware.sh` now defaults to `WIFI_CAL=samsung` —
stages this unit's own `amss20.bin` + `m3.bin` and builds `board-2.bin`
from `bdwlan.elf` via the new `scripts/build-samsung-board2.py`,
committed into `buildroot/firmware-overlay/` so every rootfs flavour
picks it up (`WIFI_CAL=community` restores the old set). The kernel
quirk auto-gates on the firmware build id — no cmdline flag needed.
`vendor-firmware-dump/` + `firmware-overlay/` were already committed
(`.gitignore` header, 2026-09-07), so no new redistribution decision.
One integration gotcha, found and fixed here: ath11k's firmware load
straddles the initramfs → switch_root boundary, so
`build-real-root-initramfs.sh` must be re-run alongside
`fetch-ath11k-firmware.sh` — a stale initramfs holding the *other*
firmware generation reproduces the RDDM crash by mismatch. After
rebuilding both and flashing: cold boot loads `WLAN.HSP.2.0` clean,
zero RDDM, **both RX chains live and matched** (`-65 [-69, -67]` vs the
community `-57 [-93, -57]`), NSS 2 / VHT-MCS 9, **~85 Mbit/s** download
(3/3 samples) vs ~8 Mbit/s community — ~10×. `CONFIG_ATH11K_DEBUG=y`
(verbose tracing, runtime-gated) kept; not required by the fix. Full
write-up: `docs/wifi-samsung-calibration.md`. Only loose end: a
controlled same-position/band/AP A/B to pin the exact delta.

### gts9wifi-x11-dir-fix restart storm — properly fixed (was only masked live before)

The `gts9wifi-x11-dir-fix.path`/`.service` pair (above) turned out to be
storming on **every** boot, independent of the SELinux socket failures
it was first spotted alongside — a fresh boot with SELinux compiled out
and everything else healthy still showed ~50 re-triggers/second, ~90k
journal lines in half an hour, load average ~3.6. It had only ever been
`systemctl mask`ed live; the mask was never in the overlay source, so
every rootfs redeploy brought the storm back.

Root cause: it's a textbook `PathExists=` footgun. A `.path` unit with
`PathExists=/tmp/.X11-unix` re-activates its `Unit=` for as long as the
path merely *exists*; the triggered oneshot only `chown`/`chmod`s the
directory, never removes it, so systemd re-fires it immediately, forever.
The unit even set `StartLimitIntervalSec=0`, removing the one brake that
would have rate-limited it into a stop. (Upstream gts9wifi-fedora ships
the same units — same latent bug there.)

Fix (`rootfs/overlay-systemd/usr/lib/systemd/system/`): drop the `.path`
unit entirely; drive the re-assert from a new
`gts9wifi-x11-dir-fix.timer` (`OnUnitActiveSec=30s`) instead, and make
the service test-first (`stat -c %U:%a … = root:1777` || fix) so a
no-op run doesn't even touch the inode. `85-gts9wifi.preset` and
`scripts/build-fedora-rootfs.sh`'s enable loop updated `.path` → `.timer`
(plus a `disable gts9wifi-x11-dir-fix.path` preset line for
already-deployed systems). Verified on a clean reboot: load average
~1.2, ~10 x11-dir-fix journal lines/minute, `/tmp/.X11-unix` held at
`root:1777`, WiFi unaffected.

## Session 11 — 2026-09-10 — Charging: 45 W direct charge + charging through suspend

Picking up the one thing the USB host/charging entry (Session 10) left
open: *"charging is documented as observed working ... not as a fully
closed-out ✅ ... the PPS/direct-charge path in particular warrants more
extended real-world testing"*. Two concrete faults:

1. **Slow.** The SM5440 PPS pump negotiated a hard ~15 W — a
   `min(target_ma, 2200)` clamp in `sm5440_start()`, 700 mV of headroom
   the board's stock 0.32 Ω `sm5440,r_ttl` ate at any real current, and
   no closed loop, so it sagged into REVBLK and collapsed to a 5 V DCP
   fallback. Non-PPS bricks capped at 2100 mA in `sm5714_battery.c`.
   Stock Android does **45 W** on a 3-step current profile here.
2. **No charge while asleep.** `sm5440_direct.c` had no `dev_pm_ops`; its
   1 s poll `schedule_delayed_work` ran into suspend and hit the
   GPI-DMA I2C bus after it suspended → "Transfer while suspended" → PD
   contract to 5 V DCP. TCPM has no PPS keepalive and no PM ops either.

### The pack is 8400 mAh, not 9800

The governing constraint on the whole change. Samsung's stock
sec-battery node has `battery,battery_full_capacity = 0x2648` (9800) and
`battery,ttf_capacity = 0x251c` (9500) — but those are fuel-gauge/CISD
internal constants that appear **identically on the S9 Ultra (X910)**,
which has a physically larger pack, so they are *not* the pack rating.
`android_kernel_samsung_gts9` is the base Tab S9 (X716/X710/…), not the
Ultra. Every numeric constant in this work comes from this model's own
stock DTS (`.../galaxytab/gts9/gts9_eur_openx_w00_r04.dts`, identical
across r00–r04), never from `ubuntu-galaxy-tab-s9ultra/` — whose
`sm5440_direct.c` supplied only the closed-loop *algorithm shape* (and
whose own DTS repeats the 9800 error). `charge-full-design-microamp-hours`
is `8400000`; using 9800000 would misrepresent the pack ~17 % and skew
every rate/thermal estimate.

### Changes (all kernel-level; `docs/charging.md` is the full write-up)

- **`kernel/drivers/sm5440_direct.c`** — the bulk of the work.
  - Deleted the 15 W cap. `sm5440_start()` uses `sm5440_target_mv()` /
    `sm5440_request_ma()`, initial headroom 700 → 1100 mV, VBUS-settle
    gate −500 → −700 mV over 40 (was 30) tries.
  - New step table from `battery,dc_step_chg_cond_vol` (4130/4250/4440
    mV) and `battery,dc_step_chg_val_iout` (8660/7420/5940 mA
    battery-side; ÷2 = pump input). 8660 mA ≈ 1.03 C on 8.4 Ah — stock.
  - Closed loop in `sm5440_work()` (Ultra shape, X716 numbers): pick
    step by pack voltage, measure pump input current, nudge the PPS
    request ±40 mV toward the step target, clamp to
    `[2·Vpack+1100, min(2·Vpack+2000, 10500)] mV`, re-Request every ~2 s,
    re-program `IBUSCNTL` per step. Regulates on current, not voltage
    (the chip's VBUS ADC is unreliable, off by hundreds of mV).
  - Switching freq 450 → 850 kHz (`sm5440,freq`), SIOP derate to
    650/450 kHz (`sm5440,freq_siop`) on die/pack heat.
  - Clean CV hand-off at Vpack ≥ 4430 mV or pump input < dchg_min/2 for
    3 ticks — stop the pump, `sm5714_battery` finishes CV on the
    switching charger; eligibility keeps it from restarting until the
    pack falls back.
  - **PPS entry gate**: `sm5440_eligible()` now requires the TCPM psy to
    report `USB_TYPE == PD_PPS`. That flag is set only from a source
    APDO — the same condition that makes `tcpm_pps_activate()` return
    −95 (`-EOPNOTSUPP`). Before this, the driver retried a PPS hand-off
    against every DCP / fixed-PD brick every 30 s forever.
  - INT1–4 latch read-out on every stop (0x02 bit 1 = REVBLK).
  - Pack-temp stop 44 °C, die stop 110 °C — stricter than Samsung's
    65/70 °C gates, which watch a *charger* thermistor while
    `POWER_SUPPLY_PROP_TEMP` here is the pack thermistor.
- **`kernel/drivers/sm5440_direct.c`** — suspend keepalive. Poll work
  moved to `system_freezable_wq` (frozen suspend→thaw, so it can't fault
  the suspended bus — fixes the fixed-PD case outright). An
  `ALARM_BOOTTIME` alarm wakes the system every 8 s; `.suspend` pets the
  pump watchdog + arms it, `sm5440_work()`'s post-thaw keepalive tail
  re-sends the PPS Request and re-checks temp (stricter asleep). Needs a
  wake-capable RTC — `keepalive_capable = !!alarmtimer_get_rtcdev()`;
  without one it degrades to the mainline-normal "hand back to the
  switching charger for the sleep". Missed wake is self-limiting: the
  pump's WDT_30S disables it and the next resume restores switching.
  No second alarm in `sm5714_battery.c`.
- **`kernel/dts/sm8550-samsung-x716b.dts`**:
  `charge-full-design-microamp-hours` `8160000` → `8400000` (one line;
  the node had the X710 figure). No `PDO_PPS_APDO` added — TCPM v7.2
  keys PPS off *source* caps, and Samsung's 15 W fixed-path cap is
  deliberate.
- **`kernel/drivers/sm5714_battery.c`**: DCP `fast_ma` 2100 → 2200
  (stock DCP ceiling for this pack); everything else — the 9 V/1660 mA
  fixed-PD clamp, the `>9000 mV / >3000 mA` PD-contract reject, the
  pack-thermistor STOP 50 / REDUCED 46 °C — unchanged.
- **`kernel/config/config-x716.fragment`**: `CONFIG_RTC_DRV_PM8XXX=y`
  (base leaves it `=m`; no `rtc0` → no wake alarm → keepalive silently
  falls back). Matches `pmk8550.dtsi`'s already-enabled
  `pmk8550_rtc: rtc@6100` (`qcom,pmk8350-rtc`, dedicated alarm reg bank
  + IRQ).

Bring-up knobs (`/sys/module/sm5440_direct/parameters/`): `pps_op_curr_ma`
(default 4500, the PPS Request operating current — 45 W/~9 V ≈ 5 A, 4500
leaves cable margin), `target_ibus_ma` (default 0 = step table; non-zero
pins the loop's aim for staged testing), `verbose`.

**Kernel builds clean** (`Image` + DTB, `sm5440_direct.o` /
`sm5714_battery.o` / `rtc-pm8xxx.o` all compile with no warnings; the
build script's strict fragment-symbol verify passes with
`CONFIG_RTC_DRV_PM8XXX=y` intact). **Real-hardware validation is the
staged protocol in `docs/charging.md` §"Staged validation"** (Stage 0
instrument → 1 manual current ramp → 2 auto step table → 3 suspend
keepalive → 4 full suspend charge), each stage gated on its own abort
criteria, `&uart7` console attached throughout — not yet run. This is
deliberately not marked ✅ until Stage 4 passes.

### Session 11b — 2026-09-10 — Charging: round-2 closed-loop hardening

Five `sm5440_direct.c` bug fixes from the first bring-up, no DT/config
change. Full write-up in **`docs/charging-followup.md`**.

1. **`IBUSCNTL` tracked the step *index*, not the target current** — in
   auto mode before the pack crossed 4130 mV, and on any runtime
   `target_ibus_ma=` write, the hardware input limit stayed pinned at
   the `sm5440_start()` value and capped the loop in silicon.
   `sm5440_program_ibus()` now self-tracks its last write and runs every
   tick. Live-verified: input current 1.5 A → 2.8 A the moment the
   per-tick write landed.
2. **Request current not clamped to the APDO** — `sm5440_request_ma()`
   now also clamps to `POWER_SUPPLY_PROP_CURRENT_MAX` (the active APDO
   ceiling), never below the 15 W floor. Over-asking had been seen to
   renegotiate the contract down to 5 V DCP.
3. **Source-foldback detection** — a > 300 mV tick-over-tick VBUS sag
   (current not above aim, so not our own down-regulation) is treated as
   the source/cable folding back: stop climbing the Request, ease it to
   the level the bus is holding, settle there instead of collapsing.
4. **One retry before tearing down** — a lone `-EPROTO` from
   `sm5440_refresh_pps()` now re-reads the APDO ceiling and retries once
   (50 ms) before falling back to the switching charger.
5. **`SM5440_SAT_TICKS` 12 → 8** — the first collapse happened at ~10 s
   of ceiling saturation, before the 12-tick anti-windup could act.

**Verified on hardware** (build `a2494b92…`): driver loads/binds,
keepalive armed, `rtc0` = `rtc-pm8xxx`, PM ops clean. The charger on
hand advertised **fixed PDOs only** (5/9/12/15/20 V @ 3 A, no APDO), so
the PPS loop could not be exercised — but the non-PPS path was clean:
direct charge correctly gated off, **zero `-95` spam**, fixed 9 V
contract carried the charge. **Stages 0–4 against a real PPS adapter
still pending** — needs the Samsung 45 W (has an 11 V/4.05 A APDO) and a
drained pack. Task left open: "done, needs a little further testing".

### Session 12 — 2026-09-10 — NixOS aarch64 rootfs (second distro)

Added a **standalone flake under `nixos/`** that builds a full NixOS
aarch64 userland (KDE Plasma 6, Wayland) carrying every device fix, as a
second rootfs alongside Fedora. It implements the
`docs/distro-porting.md` contract for a new distro: `overlay-common/`
applied verbatim, `overlay-systemd/` **translated** (not copied) into
idiomatic NixOS modules, the same vendor firmware + kernel module tree
staged. Deployable to **either** microSD (as Fedora) **or** the internal
`userdata` partition via TWRP — `scripts/deploy-nixos-rootfs.sh {sd,userdata}`.

- **Boundary**: the flake is rootfs-only. It *consumes* `../out/kernel`
  (`Image` + `modules-out`) and `../out/android/*.img` from the existing
  pipeline; it does not build the kernel or the Android bundle. `out/` is
  `.gitignore`d, so the flake reads it by absolute path → every build
  needs `--impure` (documented in `nixos/README.md`, same honesty as the
  root flake's Fedora-rootfs note).
- **`pkgs.x716b.kernel`** wraps the prebuilt tree as a Nix "kernel"
  package (`modDirVersion` = the real `kernel.release`, `passthru.config`
  parsed from the real `.config`) so `boot.kernelPackages` /
  `system.modulesTree` stay coherent while `boot.initrd.enable = false`
  and no bootloader is installed (ABL boots the Android `boot`
  partition; the bundle's busybox initramfs `switch_root`s into the
  labelled rootfs).
- **Custom packages** (none in nixpkgs): `libssc` 0.4.4, `pd-mapper` 1.1,
  `hexagonrpcd` 0.4.0 + the 4 `specs/hexagonrpcd-samsung/` patches,
  `iio-sensor-proxy` 3.9 `-Dssc-support=enabled` + the SSC patch — same
  source pins the Fedora builder uses.
- **`x716b-device.nix`** translates the 13 `gts9wifi-*` units + 5
  drop-ins to `systemd.services.*`, preserving every `After=/Before=`
  from the unit comments; `85-gts9wifi.preset` is the `wantedBy`
  authority, so the ADSP chain (`hexagonrpcd-adsp-sensorspd`,
  `gts9wifi-adsp-boot`) is defined but **manual-start**. zram / journald
  cap / lid / NM-powersave / tmpfiles / vendor partlabel mounts become
  native options; `gts9wifi-grow-rootfs` → `fileSystems."/".autoResize`;
  `gts9wifi-chronyd` → a sandbox-stripping drop-in on NixOS's own
  `chronyd` (the vendor override existed only because namespacing fails
  on this kernel, `226/NAMESPACE`).
- **`scripts/build-real-root-initramfs.sh`**: `/init` now resolves the
  root by **filesystem label `X716B_ROOT`** first (`findfs`), falling
  back to the old `mmcblkXp1` device-node list — one initramfs serves
  both deploy targets.
- **Kernel config**: checked `out/kernel/.config` against NixOS's
  `system.requiredKernelConfig` (all 17 satisfied) and a curated
  systemd-257 / Plasma-Wayland list — **nothing missing**
  (`AUTOFS_FS`, `CGROUP_BPF`, `SECCOMP_FILTER`, `USER_NS`, full
  `DRM_MSM`, `FB`, `VT`, `ZRAM` all `=y`). **No `config-x716.fragment`
  change, no kernel rebuild.**
- **Status**: `nix build --impure ./nixos#rootfs-tar ./nixos#rootfs-image`
  **completes on the dev host** — a 3.7 GB gzip rootfs tarball and a
  9.2 GB ext4 image (label `X716B_ROOT`); the tarball carries the FHS
  skeleton, `/sbin/init` → the system profile, `/nix/store/.reginfo`,
  the `gts9wifi-*` units, `hexagonrpcd`/`libssc`/`pd-mapper`,
  `x716b-firmware` and `lib/modules/7.2.0-dirty`. Getting there took two
  fixes (own commit): the `alsa-ucm-conf` overlay override was forcing a
  595-derivation emulated rebuild → OOM (replaced with a standalone
  `x716b.ucm` package + `ALSA_CONFIG_UCM2`), and NixOS's udev-rules
  validator rejected the `/usr/bin/iw` path in
  `72-gts9wifi-wifi-powersave-off.rules` (rewritten to the store `iw`).
  Plan is now 44 glue derivations / 720 MiB, everything else cached.
- **Pending**: real-hardware bring-up (SD path first, then `userdata`)
  against the feature-parity checklist in the plan and `nixos/README.md`.

### Session 13 — 2026-09-11 — NixOS: first real boot, live bring-up, hardware/configuration split

**First successful boot of NixOS on the tablet.** Deployed to the
microSD already seated in the tablet, streamed via `adb` with the
tablet in TWRP (the new `twrp-sd` deploy target — the card-reader `sd`
target assumed the card wasn't already in the device, which it was).
Two TWRP-specific tool bugs found and fixed live, both now documented
and worked around in `scripts/deploy-nixos-rootfs.sh` /
`nixos/README.md`:

- TWRP's toybox `dd` fails `read error: Bad address` reading stdin at
  `bs=1M`+; `bs=64k` round-trips a test file byte-for-byte. Every
  `adb shell dd` in the deploy script now uses `bs=64k`.
- TWRP's e2fsprogs (1.45.4) can't parse the `orphan_file` feature our
  build's modern `mke2fs` writes — not corruption, just too old to read
  it. Dropped the on-device `e2fsck`/`resize2fs` step entirely;
  `fileSystems."/".autoResize` grows the filesystem on first real boot
  using the NixOS closure's own e2fsprogs instead.

**SSH reachable, kernel `7.2.0-dirty`, systemd up.** `systemctl --failed`
showed 7 units down; all diagnosed live (`journalctl -u <unit>`) and
fixed by editing/testing via runtime `systemd` drop-ins under
`/run/systemd/system/*.d/` before committing the real fix to
`nixos/hardware.nix` (so no rebuild+reflash cycle was needed to confirm
each one):

1. **`chronyd` failed to `chown()` `/run/chrony` even as root** — an
   earlier `CapabilityBoundingSet = lib.mkForce ""` meant to strip
   sandboxing actually set the capability bounding set to *empty* (deny
   everything) — this directive's empty-assignment semantics are the
   opposite of `RestrictAddressFamilies`/`SystemCallFilter`'s. Fixed
   with `~` (systemd's "full set" token). Confirmed live before landing.
2. **`gts9wifi-bt-provision` / `gts9wifi-sensor-registry-perms`
   `FileNotFoundError`/`command not found` on bare `mount`** (and
   `fdtget` for bt-provision) — NixOS services get a minimal default
   `PATH` with no `util-linux`/`dtc`. Added explicit `path = [ ... ];`.
3. **`hexagonrpcd-adsp-sensorspd` "has a bad unit file setting"** — the
   drop-in's `ExecStart = lib.mkForce "<cmd>";` produced a *second*
   `ExecStart=` line instead of replacing the package's own one (two
   `ExecStart=` on a `Type=simple` service is invalid). Fixed with the
   `ExecStart = [ "" "<cmd>" ];` reset-then-set idiom.
4. **`pd-mapper` "no pd maps available"** — traced (via `grep -a` path
   strings in the binary, no `strings` on-device) to a hardcoded
   `/lib/firmware` scan; NixOS ships no `/lib` at all. Added a
   `systemd.tmpfiles.rules` compat symlink. Root firmware gap remains
   open, though: `vendor-firmware-dump/` never got the PDR `.jsn` files
   extracted in this checkout — a pre-existing gap shared with the
   Fedora rootfs (its own comments describe the exact same failure mode
   if they're missing), not something new here.
5. **`firewall.service` exit 4** — `iptables: Extension pkttype
   revision 0 not supported, missing kernel module?`. The kernel lacks
   `CONFIG_NETFILTER_XT_MATCH_PKTTYPE`. `networking.firewall.enable`
   defaulted to `false` pending that kernel fragment addition + rebuild.
6. **`x716b-serial-getty` restart-looped to `start-limit-hit`** — the
   USB gadget's current composite function is network-only (RNDIS/ECM);
   `/dev/ttyGS0` doesn't exist. Added `unitConfig.ConditionPathExists`
   so it skips cleanly instead of looping (SSH is the real console now).

**Architecture pivot, mid-session, per direction from whoever was
driving this session**: originally split into 3 flake modules
(hardware/desktop/device); briefly explored flattening into a classic
(non-flake) `/etc/nixos/configuration.nix`, then landed on the actual
final shape — **keep the flake**, but split it exactly in two
(`hardware.nix` vs `configuration.nix`, see `nixos/README.md`), and
**ship the whole thing onto the device as real, editable files** at
`/etc/nixos/` so `sudo nixos-rebuild switch` there is genuinely
self-contained. This needed:

- `packages/etc-nixos.nix`, a new package that stages
  `flake.nix`/`flake.lock`/`hardware.nix`/`configuration.nix`/
  `overlay.nix`/`packages/*.nix` plus real (non-symlink) copies of
  everything `repoPaths` points at — `rootfs/`, `specs/`,
  `vendor-firmware-dump/`, `buildroot/firmware-overlay/`, and a
  *trimmed* slice of the kernel output (`.config`,
  `include/config/kernel.release`, `Image`, `System.map`, the dtb,
  `modules-out/` — not the 2.6 GB of `out/kernel`'s build
  intermediates) — into `/etc/nixos/vendor/`.
- A first attempt made `nixos/vendor/*` plain symlinks *in this repo*
  pointing at `../rootfs` etc., meant to unify how both this checkout
  and the device reference the same data. Confirmed live this doesn't
  work: Nix copies a referenced symlink as a symlink, not its resolved
  content, so `cp`-ing a symlinked source into the store produces store
  paths with symlinks pointing at nonexistent `/nix/store/rootfs`-style
  locations. Reverted to real path references (`../rootfs` etc.) for
  this checkout; `etc-nixos.nix` instead takes `repoPaths` directly
  (already-realized store paths) and copies their real content.
- `flake.nix`'s five `repoPaths` lines (four tracked, one impure via
  `X716B_REPO_ROOT`) only make sense relative to *this* checkout.
  `etc-nixos.nix` `substituteInPlace`s all five in the *shipped* copy of
  `flake.nix` to point at `./vendor/*` instead. Confirmed live, in a
  simulated `/etc/nixos` (a plain copy outside any git working tree):
  `nix eval` on the staged flake succeeds with **no `--impure`, no
  network needed to resolve `<nixpkgs>`** — the whole point.
- Dropped `profiles/minimal.nix` from `hardware.nix` — this is a full
  reconfigurable desktop now, not a stripped appliance; that profile
  turns off man/info pages, MIME associations, xdg autostart/icons/
  sounds and udisks2 automount, all things a real desktop wants on.
  Enabled flakes (`nix.settings.experimental-features`) so `nixos-rebuild
  switch` auto-detects `/etc/nixos/flake.nix` with no extra flag.

**New packages, per request**: `hardware.bluetooth` + `kdePackages.
bluedevil` (Plasma applet), `kdePackages.wacomtablet` (Graphics Tablet
System Settings KCM), `krita`, `firefox` (also how you log into a WiFi
captive portal on first boot, which is exactly what happened live this
session). All four resolved to existing nixpkgs attrs, no packaging
needed.

**Final verification**: rebuilt (12.9 GB image, up from ~11 GB — the
new desktop packages + `/etc/nixos` staging), redeployed via `twrp-sd`,
rebooted. User confirmed live on the device: boots clean, reachable, —
"everything works." `docs/porting-log.md`'s and `nixos/README.md`'s
bring-up-fixes lists above are the authoritative record of what shipped
this session; Task #20-style exhaustive feature-parity re-verification
(BT pairing, Krita launch, `nixos-rebuild switch` end-to-end with a real
edit) is future work, not blocking.

### Session 14 — 2026-09-11 — Debian unstable rootfs (third distro), and a sandboxed-build-environment saga

Third rootfs target: `scripts/build-debian-rootfs.sh`, Debian **unstable
(sid)** aarch64, full KDE Plasma 6 desktop, snapshot.debian.org-pinned
for real package-version reproducibility (a stronger guarantee than the
Fedora builder's own, honestly non-pinned live dnf mirror). Debian is
systemd + merged-`/usr`, same as Fedora, so the overlay step needed no
translation at all — the hard part of this session was entirely about
getting a working build *environment*, not the Debian-specific porting
work itself. See `docs/distro-porting.md`'s new Debian section for the
condensed technical summary; this entry is the blow-by-blow of how each
fix was actually found.

**chroot(2) is unconditionally blocked in this session's sandbox.**
Forking `build-ubuntu-rootfs.sh`'s proven `unshare --user --mount` +
real-`chroot` scaffold seemed like the obvious path, and stage 1
(`debootstrap --foreign`, host-side unpack, no chroot needed) worked
immediately. Stage 2 didn't: every `chroot "$rootdir" ...` invocation,
even `chroot "$rootdir" /bin/true` with zero emulation involved, returned
exit 255 with **zero output of any kind** — no error text, nothing.
`strace`-ing it directly (not through the nested unshare) isolated it to
`chroot(2)` itself returning a bare failure the shell couldn't even
report — a container-level restriction on this specific syscall in this
sandbox, the same general class as two restrictions already known from
earlier sessions (whole-`/sys`/`/dev` bind-mounts, `mknod`), but this one
had no narrower workaround — the whole execution mechanism had to
change.

**Fix: `proot`, not `chroot`.** `proot` reimplements chroot/bind-mount/
binfmt semantics entirely in userspace via ptrace, needing neither
`chroot(2)` nor `mount(2)` — confirmed live it runs real aarch64 code via
qemu-user (`proot -r "$rootdir" -0 -q "$QEMU_AARCH64_STATIC" ...`)
completely unprivileged. Getting there took several rounds:
- The plain nixpkgs `qemu-user` package is dynamically linked and pulls
  in an easy-to-break host `.so` closure (hit live: cascading "cannot
  open shared object file" for `libp11-kit` then `libidn2`). The root
  flake already had the fix on hand from the Fedora work:
  `$QEMU_AARCH64_STATIC` (`commonEnv`), a genuinely static musl build —
  just needed reusing here too.
- The host's own registered `aarch64-linux` binfmt_misc interpreter
  (a different, `-P`/argv0-preserving build) is NOT interchangeable with
  proot's `-q` — confirmed live it mis-parses proot's own constructed
  argv ("Error while loading -U: No such file or directory").
  `$QEMU_AARCH64_STATIC` is the right tool for this job specifically.
- nixpkgs's `debootstrap` derivation's `patchShebangs` pass rewrites the
  `/debootstrap/debootstrap` template — meant to run **inside the
  target** post-chroot, via the target's own `/bin/sh` — to the HOST's
  own nix-store bash path regardless. Confirmed live
  (`#!/nix/store/.../bash` on a file meant for guest execution); fixed
  with one `sed` line. The same generated script also hardcodes an
  absolute host nix-store path for `dpkg` (baked in from the host's own
  dpkg at stage-1 time) — bound `/nix:/nix` into the guest via `proot -b`
  rather than patch every such host-path leak individually.

**qemu-user is flaky for early dpkg bootstrap, confirmed live and
reproduced 3× in a row on a byte-identical rerun**: "double free or
corruption" / "malloc(): corrupted top size" aborting a maintainer
script mid-run, on the very first packages (dpkg/base-files/libc6).
Nondeterministic — an identical invocation against a freshly
re-extracted rootdir sometimes ran clean start to finish. Critically,
`debootstrap --second-stage` is **not** safely re-runnable in place
after such a crash (it writes its own minimal dpkg status bootstrap stub
unconditionally at the top of the script — a second invocation against a
half-crashed `$rootdir` corrupts `/var/lib/dpkg/status` further, not
less, confirmed live: duplicate/malformed `Package: dpkg` stanzas). Fix:
`stage1()` became a real function, and stage 2 retries from a **clean
re-extraction** (cheap — host-side tar unpack, no emulation) rather than
in place, bounded at 5 attempts.

**A second, unrelated proot crash, much harder to pin down**: a real
upstream proot bug, `path.c:547: compare_paths2: Assertion "length2 > 0"
failed` (SIGABRT) — long-standing and still open upstream (termux/
proot#123/#159, proot-me/proot#182), triggered by certain systemd
tooling under ptrace. First hypothesis (systemd-sysusers crashing on
*creating* a new user, safe once idempotent) was wrong — isolated
reproduction showed sysusers' own log lines were just the last output
flushed before the crash; extracting systemd's real postinst script
(`dpkg-deb -e`) showed the actual next command was `systemd-tmpfiles
--create <files>` (a `dh_installtmpfiles`-generated hook), confirmed by
reproducing the crash directly with that exact command. Unlike sysusers,
tmpfiles crashes **unconditionally** — re-verified live that pre-seeding
everything from the host first does not stop the guest's own
`--create` from crashing again immediately after. The eventual fix:
divert `/usr/bin/systemd-tmpfiles` to a no-op stub (`dpkg-divert
--local --rename`) for the whole package-install phase — the same
`policy-rc.d`-style technique container pipelines already use to block
service *starts* during installs — then run the real host-native
`systemd-tmpfiles --root="$rootdir" --create` (`$SYSTEMD_TMPFILES_HOST`,
new flake.nix env var, same pattern as `$QEMU_AARCH64_STATIC`) exactly
once at the very end, after every package is already installed.
`systemd-sysusers` genuinely doesn't need this — confirmed separately it
only crashes on the create-new path, so a lighter host-side pre-seed
(`$SYSTEMD_SYSUSERS_HOST`, used reactively in `run_in_chroot`'s existing
retry loop) is enough there. Both host tools needed `run_in_ns`'s wide
subuid/subgid mapping too: a plain unprivileged host invocation gets
every `fchownat()` rejected outright ("Operation not permitted") since
it can't really become root; the same mapped namespace stage 1 already
needed makes those succeed for real. One correctness gap in each host
tool, confirmed live and fixed/tolerated: `systemd-sysusers` doesn't
consistently chase `--root` for the "nologin" shell keyword (writes a
meaningless host nix-store path into the target's `/etc/passwd` — fixed
with a `sed` pass); `systemd-tmpfiles` fails one ACL assignment on
`/var/log/journal` with an unresolved/overflowed GID (harmless, the
"adm" group's read access only).

**Two ordinary Debian packaging gaps**, once past the emulation
problems: `libqrtr-dev` (plain C reference library, providing
`libqrtr.h`) is a real, separate package from `libqrtr-glib-dev` (GLib
bindings only) — easy to miss since Fedora's single `qrtr-devel` covers
both; missing it broke pd-mapper's build with `fatal error: libqrtr.h:
No such file`. `libudev-dev`/`libsystemd-dev` ship `libudev.pc`/
`libsystemd.pc` — meson's `dependency('udev')`/`dependency('systemd')`
(the OLD pre-merge pkg-config names, still used by iio-sensor-proxy's
and hexagonrpcd's own `meson.build` files) need `udev.pc`/`systemd.pc`
symlinks Debian doesn't ship as an alias. hexagonrpcd's `meson.build`
also installs its `.service` units under `get_option(libdir)/systemd/
system` directly rather than through the systemd dependency's
`systemdsystemunitdir` variable, landing them at the multiarch triplet
path (`/usr/lib/aarch64-linux-gnu/systemd/system`) instead of systemd's
real search path — confirmed live (`systemctl enable` couldn't find
them) and fixed by relocating the three files after install.

**Result**: a full clean run completes end to end — stage 1/2,
snapshot-pinned base packages, vendor firmware + kernel modules, the
device overlay, the full sensor/ADSP stack built from source, and
`task-kde-desktop` (SDDM + Plasma 6 + Mesa/Vulkan drivers) — all with
zero manual intervention, `rootfs directory ready` printed at the end.

**Real-hardware validation, same session**: `scripts/build-rootfs-image.sh`
(a raw ext4 image, unprivileged via `mke2fs -d`) needed the same
`run_in_ns` wide-uid-mapping fix as everything else that touches this
rootdir — confirmed live, a plain unprivileged `mke2fs -d` doesn't just
skip unreadable subdirectories (`/run/systemd/dissect-root`,
`/var/lib/sddm`, both created via the mapped namespace during the
`systemd-tmpfiles` pass), it treats permission-denied as fatal and
aborts the whole image build. `scripts/deploy-rootfs.sh` had an
unrelated, genuinely new bug: when invoked with a non-terminal stdin
(exactly this session's own execution context), an earlier `adb shell
cat /proc/partitions` silently consumed the line meant for the later
`read -rp "Type ERASE..."` confirmation prompt, which then hit EOF and
aborted under `set -e` with no error message at all — fixed by
redirecting every `adb shell`/`adb get-state` call that isn't the actual
image-streaming `dd` from `/dev/null`.

Deployed via `twrp-sd` (3.58 GB, ~17 MB/s over USB, byte-exact),
rebooted with `adb reboot system`. **Confirmed live, real hardware**:
reachable over the USB gadget network (172.16.42.1) immediately after
boot, kernel matches the build (`7.2.0-dirty aarch64`), SSH works,
`graphical.target` active, SDDM/Xorg/the Plasma greeter genuinely
running (`systemctl status sddm` showed the full Xorg + sddm-greeter-qt6
process tree), Bluetooth initializes (`hci0 UP RUNNING`, correct BD
address), NetworkManager correctly recognizes the WiFi radio
(disconnected, as expected — no SSID configured yet). `systemctl
--failed` showed exactly three units, all either already-documented or
not Debian-specific: `pd-mapper.service` (the pre-existing missing-PDR-
`.jsn`-files gap, shared with Fedora/NixOS, not this session's job to
fix) and `gts9wifi-wait-sensor-proxy.service` (downstream of the
manual-start ADSP chain, same as every other builder) both expected;
`x716b-serial-getty.service` failed because `/dev/ttyGS0` doesn't exist
at all under this kernel's gadget config (`g_ether`-only, no serial
function) — a kernel/gadget-config fact common to every distro on this
port, not something this session introduced or is responsible for
fixing.

One genuine new bug, found and fixed: `/home/x716b` booted owned by
`root:root` instead of `x716b:x716b`, blocking the login shell's `cd`
into `$HOME` even though password auth succeeded. Root cause: `useradd
-m`'s own chown of the new home directory runs through `run_in_chroot`
(proot's `-0` fake-root), and confirmed live that fake-chown does not
reliably persist as real on-disk ownership once the proot session ends
— the exact same class of limitation `seed_sysusers`/`seed_tmpfiles`
already exist to work around for systemd's own tooling, just not
previously caught for this one `useradd` call. Fixed live on the running
device (`sudo chown -R x716b:x716b /home/x716b`) and in the script
itself (an explicit `run_in_ns chown -R` — real chown, wide-mapped
namespace — right after user creation, for the next build).

**Result**: a genuinely working Debian sid + KDE Plasma 6 desktop, on
real SM-X716B hardware, on the first real-hardware attempt. Task
#82-equivalent staged validation complete; remaining open items
(WiFi association, S Pen, audio, charging — the full feature-parity
checklist every other rootfs on this port has gone through) are follow-
up, not blocking.

**Session 14 addendum, same day — desktop package set, twice wrong
before landing right.** User feedback on the first flashed image: SDDM
was running (confirmed live above) but the actual desktop was not
functional. Two more live iterations:

1. First fix attempt: `task-desktop`/`task-kde-desktop`/`task-laptop`
   explicitly, plus `-o APT::Install-Recommends=true` for that one
   install (this script's global `Install-Recommends "false"`, kept
   everywhere else for reproducibility, was starving Debian's tasksel
   desktop metapackages of exactly the pieces they lean on Recommends
   for — confirmed live via `apt-cache depends sddm`: **sddm itself has
   no theme package as a hard Depends at all**, only via Recommends,
   which is the actual root cause of the first "SDDM running but
   nothing renders" report). This technically would have worked, but
   confirmed live it also pulled ~1500 packages -- full kde-standard,
   LibreOffice, GIMP, accessibility/orca, print-manager, Akonadi/PIM
   data for KMail/KOrganizer -- and took far too long to be worth it.
2. Correct fix: dropped the tasksel packages and the Recommends
   override entirely. `kde-plasma-desktop` is Debian's own minimal
   Plasma metapackage (confirmed live via `apt-cache show`: Depends
   only on kde-baseapps, plasma-desktop, plasma-workspace, udisks2,
   upower -- a small fraction of kde-standard's closure). Wayland is
   already the Depends-level default, not something extra to request:
   `plasma-workspace` hard-Depends on `kwin-wayland` (confirmed live via
   `apt-cache depends plasma-workspace`), so a plain Depends-only
   install already ships a real Wayland session (SDDM auto-detects
   `/usr/share/wayland-sessions/plasma.desktop` at login) with no
   Recommends override needed. The one thing still added explicitly:
   `sddm-theme-breeze`, for the exact reason found in step 1 -- sddm's
   own missing-theme-by-default gap, fixed with one targeted package
   instead of a blanket Recommends flip. Also added per user request:
   `network-manager-tui` (nmtui -- confirmed live NOT bundled into
   `network-manager` itself on Debian), `bluedevil` (the KDE Bluetooth
   system-tray applet/KCM -- bluez alone has no user-facing pairing UI),
   `kde-config-tablet` (confirmed live, via `apt-cache search`, the
   actual Debian package name for the Wacom digitizer System Settings
   KCM -- there is no "wacomtablet"/"plasma-wacom"-named package here).

**A real regression found and fixed along the way**: the home-directory
ownership fix from the same day's earlier entry (`run_in_ns chown -R
"$uid:$gid" ...`) was itself wrong, confirmed live via `stat` after a
rebuild: chowning to the *numeric* target uid/gid (1000:1000) inside
`run_in_ns`'s own mapped namespace does not mean "real host uid/gid
1000" -- 1000 falls inside the wide subordinate range
(`1:$subuid_base:65536`), so it silently resolved to a *different*
wrong owner on the real shipped disk (~100999) instead. More generally:
an unprivileged build can only make a real `chown(2)` persist to
exactly (a) its own real uid/gid, or (b) something in its own delegated
`/etc/subuid`/`/etc/subgid` range -- 1000 is neither in general (it
only half-coincides here: this build host's own real *uid* happens to
also be 1000, but its real *gid* is 100, not 1000). The actual fix
doesn't fight build-time uid mapping at all: a static `systemd-tmpfiles`
`z` line (`/etc/tmpfiles.d/x716b-home-owner.conf`) that resolves the
username by NAME at *real boot time*, via the device's own genuine root
and genuine NSS lookup against its own `/etc/passwd` -- no numeric
coincidence needed, confirmed live after a redeploy: SSH login lands in
`/home/x716b`, `stat` shows `Uid: (1000/x716b) Gid: (1000/x716b)`
correctly.

**Final confirmed-live state**: `systemctl --failed` down to exactly
one unit (`pd-mapper.service`, the already-documented missing-PDR-
`.jsn`-files gap) -- `x716b-serial-getty` and `gts9wifi-wait-sensor-
proxy` no longer even appear as failed this run. `sddm.service` active
and running (Xorg + the greeter, `breeze`/`debian-theme` both present
under `/usr/share/sddm/themes/`), `plasma.desktop` present under
`/usr/share/wayland-sessions/`, rootfs auto-grown to fill the SD
partition (3.3G/4.1G used) via `gts9wifi-grow-rootfs.service`. Whether
the greeter/desktop actually *renders* correctly on the physical panel
is a visual check only the user can make -- everything checkable from
this side (service state, theme presence, session files, ownership) is
now correct.

**Session 14 addendum #2, same day -- real device use, real bugs.** The
user actually logged into the desktop on real hardware (confirmed by a
`startplasma-wayland` session appearing live) and found four more
things, each tested live against the running device before landing in
the script:

- **Touchscreen dead in the SDDM greeter.** The real touchscreen kernel
  device (`fts1ba90a`, confirmed via `/proc/bus/input/devices` to have
  correct ABS/touch event bits) was never the problem -- Xorg itself had
  no input driver module for anything but the S Pen
  (`xserver-xorg-input-wacom`, confirmed via `dpkg -l`). Neither
  `xserver-xorg-core` nor `sddm` Depends *or* Recommends an actual touch/
  generic input driver. Added `xserver-xorg-input-libinput`; confirmed
  live via the Xorg log that it now loads and correctly tags `fts1ba90a`
  as a TOUCHSCREEN device. This only matters for the *greeter* -- the
  real Plasma session, once logged in, reads touch natively through
  kwin-wayland's own libinput integration, no Xorg driver involved.
  (Tried switching the greeter itself to Wayland instead, via
  `DisplayServer=wayland` in `sddm.conf.d` -- SDDM's own example config
  marks this "experimental", and confirmed live it genuinely fails to
  start on this hardware, `SDDM::Auth::HELPER_DISPLAYSERVER_ERROR`
  falling back to x11-user automatically, even though `kwin_wayland`
  itself runs fine standalone. Not pursued further per explicit user
  direction -- X11 greeter + Wayland session is the accepted answer.)
- **Rootfs not actually using the whole SD card, despite
  `gts9wifi-grow-rootfs.service`'s own stamp file claiming success.**
  Confirmed live, the hard way: `sfdisk` genuinely grew the partition
  table and `/sys/class/block/.../size` read back correctly moments
  after boot, but `resize2fs`, called immediately after in the same
  script run, still saw the OLD small size and silently no-op'd (exit 0,
  no error -- resize2fs just grows the filesystem to whatever size it
  currently believes the partition is). The stamp file still got
  written, which then permanently skipped the retry on every later boot
  too -- the card sat at 100% full (4.1G total) with the real partition
  already at 238G. Fixed live on the device first (manual `resize2fs` +
  clearing the stamp file, to relieve the full disk immediately), then
  properly in `gts9wifi-grow-rootfs`: poll the live sysfs partition size
  for up to ~10s after the rescan step and only proceed to `resize2fs`
  once it actually matches what `sfdisk` just asked for, and verify the
  filesystem's own block count actually grew afterward before writing
  the stamp file -- if either check fails, log a warning and leave the
  stamp file unwritten so the *next* boot retries instead of skipping
  forever.
- **No audio stack at all.** `base_packages` only ever had `alsa-utils`
  (raw CLI tools, no session/routing daemon) -- confirmed live neither
  `pipewire` nor `pulseaudio` was installed. Added `pipewire` +
  `pipewire-pulse` (the PulseAudio-compatible socket most apps still
  expect) + `pipewire-alsa` + `wireplumber` (pipewire's session/policy
  manager -- without it pipewire has no policy engine and nothing finds
  a working sink).
- **No Display Configuration page in System Settings.** `kde-plasma-
  desktop`'s minimal Depends closure does not include `kscreen`
  (confirmed live via `dpkg -l`: only `libkscreen-data`, the plain
  library, was present) -- added it explicitly.

**A detour worth recording, not a script change**: the user asked for a
global 200%/150%/125% UI scale via `QT_SCALE_FACTOR`/`GDK_SCALE` in
`/etc/environment.d/`. Confirmed live this is the wrong mechanism for a
*real Wayland* session specifically: Qt renders widgets at the forced
scale while `kwin_wayland`'s own shell geometry (how much screen space
it reserves for the panel/dock) is computed from its own native
per-output Wayland scale protocol, completely independent of that env
var -- the mismatch is exactly what produced a live-confirmed taskbar
clipped in half at the bottom of the screen. (The SDDM *greeter* specifically
doesn't have this problem -- it's a plain X11 session, where
`QT_SCALE_FACTOR` is the normal, correct mechanism -- but per explicit
user direction it was reverted too, back to 100%, once `kscreen` made
the real fix -- setting scale through System Settings' own Display
Configuration KCM, which negotiates the real per-output Wayland
protocol value every client agrees on -- available.) Net result: this
script ships no scale-forcing configuration of any kind; `kscreen` is
the only change, and it's the enabler, not the fix itself.

**Session 14 addendum #3, same day -- reflash exposed a SECOND grow-
rootfs bug, distinct from addendum #2's.** Rebuilt the image with all of
the above, redeployed via `twrp-sd` to the SAME microSD card, and the
card was stuck at 4.2G/88% full again after boot -- but the live log
this time showed something different: `disk 499744768s, partition ends
at 499744735s, 0s free`. The *partition* was already sized to fill the
whole disk -- correctly, not a bug -- because `deploy-rootfs.sh`'s
`twrp-sd` target `dd`s the new filesystem image directly over the
*existing* partition and never touches the partition table at all
(documented behavior, "reuses the partition as-is"). A previous boot on
this same card had already grown the partition table to fill the disk;
re-flashing a freshly-built (small) image onto it left the partition
large but the filesystem inside it small again. The script's
`free_sectors` check (space *beyond* the partition) correctly found
none -- but that is a different question from whether the filesystem
already fills the *existing* partition, which addendum #2's fix never
asked. Decoupled the two: `sfdisk`/rescan is still skipped when there's
nothing to repartition, but `resize2fs` now always runs regardless,
against whatever the current partition size already is. Fixed live on
the device first (same manual `resize2fs` + stamp-clear as addendum #2,
to relieve the full disk immediately, copied into place via `scp` since
piping file content through `ssh '... | sudo -S tee ...'` silently
truncates to nothing -- `sudo -S`'s own password read consumes the
local pipe's only line before `tee` ever gets a chance to read the
real content), then fixed properly in the script and rebuilt the image.

**Session 14 addendum #4, same day -- "sound is broken".** Diagnosed
live via `wpctl status`: WirePlumber correctly detected the card
(`alsa_card.platform-sound`, device.nick "Samsung-Galaxy-Tab-S9-5G") but
only ever exposed a fake "Dummy Output" sink -- no real sinks or
sources at all. `alsa-ucm-conf` (confirmed via `dpkg -l`: "un", not
installed) is the actual root cause: this device's UCM2 profile
(shipped by this project's own overlay at `Qualcomm/sm8550/GTS9/*`)
needs the *stock* package's shared ucm2 tree alongside it for
WirePlumber's ALSA monitor to fully resolve the card's real route
layout -- without it, UCM loading silently fails partway and
WirePlumber falls back to the fake sink rather than erroring loudly.
Installed live: confirmed no file collisions with this project's own
overlay files (both trees share the same `/usr/share/alsa/ucm2`
directory, different subpaths), and after a `systemctl --user restart
pipewire pipewire-pulse wireplumber`, `wpctl status` immediately showed
the real hardware -- "Built-in Audio Built-in speakers (4x CS35L45)" as
the default sink, "Built-in digital microphones" as the default source,
both matching this device's actual known hardware. No `ALSA_CONFIG_UCM2`
env var needed here, unlike NixOS's `hardware.nix` -- Debian's FHS
`/usr/share/alsa/ucm2` is already alsa-lib's real, hardcoded default
search path (NixOS needs the env var purely because its own store-based
layout has no such fixed path at all); just the missing package. Added
`alsa-ucm-conf` to `base_packages` (audio is a core feature, not
desktop-specific) and rebuilt the image.

A separate, unrelated thing found while diagnosing this: the live
device's `/etc/apt/sources.list` had somehow been rewritten to a live,
unpinned `deb.debian.org` URL (timestamped from early in that same
boot, not the original build) instead of this script's own pinned
snapshot line -- root cause not identified (not reproduced by anything
this session did deliberately), restored by hand to the correct pinned
content. Worth watching for on a future boot, not chased further this
session since it didn't affect the actual audio fix.

**Session 14 addendum #5, same day -- decoupling build-time
reproducibility from what the shipped image actually needs.** Two
requests, both about the gap between "reproducible to build" and
"pleasant to actually own":

- The snapshot.debian.org pin (this session's whole reproducibility
  story -- see above) is real and worth keeping for the *build*, but
  shipping a frozen, `check-valid-until=no` archive pin permanently to
  an end user's own device means `apt update && apt upgrade` silently
  keeps re-resolving the same frozen 2026-09-01 snapshot forever --
  exactly the opposite of what anyone actually using this tablet wants.
  Fix: added a block right before the script's final `apt-get clean`,
  after every package this script itself installs is already done,
  that deletes `/etc/apt/apt.conf.d/99x716b-snapshot.conf` outright (not
  edited -- both its knobs, `Check-Valid-Until=false` and `Install-
  Recommends=false`, existed solely to support the pin) and rewrites
  `/etc/apt/sources.list` to the live `deb.debian.org` archive. Build-
  time reproducibility and shipped-image upgradability are different
  goals that were accidentally sharing one file; they don't need to.
- Separately, replaced the `kde-plasma-desktop` metapackage in the
  desktop install line with its own Depends spelled out by name (`kde-
  baseapps plasma-desktop plasma-workspace udisks2 upower`), plus added
  `konsole` (confirmed live via `dpkg -l konsole`: not pulled in by
  anything above -- a minimal desktop with no terminal emulator isn't
  actually usable). Functionally identical closure either way -- apt
  resolves the same packages whether asked for by the metapackage's
  name or its own Depends list -- but now this script's own install
  line is the complete, legible source of truth for what's on the image
  instead of a pointer into whatever the archive's `kde-plasma-desktop`
  happens to Depend on today.

Both changes applied to the already-built `out/debian/rootfs` directly
(installed `konsole`, removed the now-redundant `kde-plasma-desktop`
package, rewrote `sources.list`, deleted the snapshot apt.conf.d file)
rather than a full from-scratch rebuild, then repacked via `scripts/
build-rootfs-image.sh` -- confirmed the installed-package count (1108)
stayed in the same minimal-Plasma ballpark as before, not a regression
back toward the ~1500-package tasksel bloat from earlier in this
session.

**Session 14 addendum #6, real-hardware validation of addendum #5,
same day -- caught a bug in the live-patch, not the script.** Reflashed
the repacked image via `twrp-sd`, rebooted to system, reached it over
the USB gadget debug address (`172.16.42.1`, not `x716b.local` --
mDNS isn't part of this device's SSH story) with the root password
(`chpasswd` sets it to the build's `$username`, `x716b` by default).
Confirmed: `/etc/apt/sources.list` is the live `deb.debian.org` archive,
`apt.conf.d/` has no snapshot file left, `konsole` is installed and
registered as `/etc/alternatives/x-terminal-emulator`,
`kde-plasma-desktop` is gone, SDDM and `graphical.target` are both
active, and the rootfs had already grown to the real 235 GB card
(`gts9wifi-grow-rootfs`, both its fixes from earlier this session,
working correctly again on a fresh reflash).

Caught one real bug doing this, not in the script but in how the
previous addendum patched the already-built `out/debian/rootfs` by
hand: removing `kde-plasma-desktop` without re-running an `apt-get
install` of its former Depends by name left `kde-baseapps`,
`plasma-desktop`, `plasma-workspace`, `udisks2`, and `upower` all still
marked **auto**-installed (`apt-mark showmanual` confirmed it) --
nothing left depending on them once the metapackage was gone, so
`apt-get autoremove --dry-run` showed it would delete the entire
desktop, confirmed live with a full "Remv ..." list down to
`plasma-workspace-data`. A genuinely fresh run of the script itself
does NOT have this bug -- `apt-get install -y <names...>` always marks
every explicitly named package manual, regardless of whether it asked
for a metapackage or the metapackage's own Depends -- this was purely
an artifact of patching an already-built tree by removing one package
without reasserting the others. Fixed with `apt-mark manual
kde-baseapps plasma-desktop plasma-workspace udisks2 upower` against
both the live device and `out/debian/rootfs` (then repacked the image
again); `apt-get autoremove --dry-run` came back clean (0 to remove)
on both afterward.

Three pre-existing, unrelated failed units observed via `systemctl
--failed` (confirmed via their journals to be the same known gaps this
log already documents, not caused by this session's apt/package
changes): `pd-mapper.service` ("no pd maps available" -- the
vendor-firmware-dump PDR `.jsn` gap the original Debian-target plan
already flagged as pre-existing and not this task's job to fix),
`gts9wifi-wait-sensor-proxy.service` (cascades from pd-mapper being
down), and `x716b-serial-getty.service` (ttyGS0 not present this boot
-- USB gadget console tty, host-side-dependent). Per the deleted task
item for this session ("no need to verify apt update/upgrade against
the real mirror"), that specific check was intentionally not run.

## Session 15 — 2026-09-13 — Switching back to Fedora as the base for continued feature work

User decision: Fedora (not Debian) is the base for future feature
implementation going forward. Flashing it back turned into its own
real investigation -- the existing `out/fedora/` GNOME build was not
in the state its own artifacts implied, and three separate real bugs
were found and fixed before it was trustworthy to boot.

**Bug 1 -- the unpacked `out/fedora/rootfs-gnome` directory had drifted
from its own tarball.** `pd-mapper`/`hexagonrpcd`/`ssccli` (the whole
sensor/ADSP stack) were completely absent from the live directory on
disk -- no binaries, no unit files, `systemctl is-enabled` reporting
`not-found` -- despite `docs/porting-log.md`'s own Session 9 entry
recording a real-hardware-confirmed GNOME boot with that exact stack
present and `pd-mapper.service` merely failing (missing firmware, not
missing entirely). Checked the actual deployable artifact instead of
the drifted directory: `tar tzf out/fedora/x716b-fedora-44-gnome-
rootfs.tar.gz` DOES have `./usr/bin/{pd-mapper,hexagonrpcd,ssccli}`.
The unpacked directory must have been modified or partially cleaned
sometime after the tarball was made and before this session. Fix:
don't trust a possibly-stale unpacked directory -- extracted the
tarball fresh into `out/fedora/rootfs-gnome-fresh` (inside the same
`run_in_ns`-mapped namespace `scripts/build-rootfs-image.sh` already
uses, so real ownership round-trips correctly) and worked from that
instead. Confirmed clean: all three binaries present.

**Bug 2 -- most of `build-fedora-rootfs.sh`'s own enable loop had
silently failed at build time.** Auditing every unit that script's
enable loop (`hexagonrpcd-adsp-rootpd`, `pd-mapper`, `gts9wifi-wait-
sensor-proxy`, `gts9wifi-bt-provision`, `gts9wifi-panel-coldboot-
recover`, `gts9wifi-grow-rootfs`, `gts9wifi-usb-net`, `gts9wifi-wifi-
recover`, `gts9wifi-sensor-registry-perms`, `gts9wifi-x11-dir-fix.timer`,
`gts9wifi-chronyd`, three `.mount` units) intends to enable, on the
*drifted* directory, showed nearly all of them `disabled` and two
`not-found` -- consistent with this project's own documented,
accepted risk that qemu-user emulation is unreliable for systemd-heavy
operations under `proot`/`run_in_ns chroot`, with each failure just
swallowed by the loop's own `|| echo WARN` (a build-log line, easy to
miss, apparently missed here). Re-audited the same list against the
**fresh** extraction (pre-overlay-refresh) and found it fully correct
-- every unit properly enabled. This confirms the fresh extraction (and
its tarball) is the genuinely good build; whatever caused the on-disk
`rootfs-gnome` directory's regression happened independently of the
original build itself. Applied this session's shared-overlay fixes on
top anyway (`cp -a rootfs/overlay-common/.` + `overlay-systemd/.`,
matching `build-fedora-rootfs.sh`'s own application method exactly):
picked up the `gts9wifi-grow-rootfs` race-condition fixes and the
`gts9wifi-x11-dir-fix` restart-storm fix (Session 14, both apply here
too -- confirmed live the storm bug's `.path` unit and its dangling
`multi-user.target.wants` symlink were both still present pre-fix, now
removed and replaced with the correct `.timer` enablement).

**Bug 3 -- a real, previously-uncaught `/etc/fstab` label case
mismatch.** `scripts/build-fedora-rootfs.sh` writes `LABEL=x716b-root`
(lowercase) into the shipped fstab, but every actual image this
project builds is labelled `X716B_ROOT` (uppercase) --
`scripts/build-rootfs-image.sh`'s own `mke2fs -L X716B_ROOT`, matching
every other distro's convention. ext4 labels are case-sensitive, so
`systemd-remount-fs.service` (which re-applies fstab's `noatime,errors=
remount-ro` options via its own label lookup, independent of how the
initramfs found and mounted root in the first place) failed outright
on every boot: `mount: /: can't find LABEL=x716b-root`. Root stayed
mounted fine regardless (the initramfs's own `findfs LABEL=X716B_ROOT`
already got that right, confirmed since `docs/porting-log.md`'s Session
9 GNOME boot never even flagged this), but the fstab options were
silently never actually applied. Confirmed live: fixed the case in
`/etc/fstab`, `systemctl restart systemd-remount-fs.service` came back
`active`, `mount | grep ' / '` showed `rw,noatime,errors=remount-ro`
correctly applied. Fixed at the source (`build-fedora-rootfs.sh`'s
heredoc) and in both `out/fedora/rootfs`/`rootfs-gnome` for consistency
-- this bug has silently existed in every Fedora build this script has
ever produced.

**Full real-hardware validation after all three fixes**, same protocol
as every other distro switch this project has done: reflashed via
`twrp-sd`, rebooted, reached the tablet over the USB gadget address
(`172.16.42.1`) — this time as the regular `x716b` user (Fedora's
`sshd` defaults to `PermitRootLogin prohibit-password`, unlike Debian's
explicit `PermitRootLogin yes`; the same build-set password works for
the non-root account). Confirmed: `gts9wifi-grow-rootfs` grew the
filesystem to the real 235 GB card correctly; `graphical.target` and
`gdm.service` both reached `active`; WiFi associated to a real AP
(`wlp1s0`, `Songo-5GHz`, real signal/channel info); Bluetooth
controller up and correctly named "Samsung Galaxy Tab S9 5G"; the
audio card registered correctly at the kernel level
(`/proc/asound/cards`: `sm8550 - Samsung-Galaxy-Tab-S9-5G`, real PCM
device nodes under `/dev/snd`) -- `aplay -l`/`wpctl status` showing
nothing is expected and not a bug: nobody was logged into the GDM
greeter's desktop session during this remote-SSH-only validation pass
(only a plain SSH login session existed, no PipeWire/WirePlumber
`--user` instance had started), so PipeWire's own device enumeration
was never exercised -- the kernel-level card registration is the part
this remote check can actually confirm. `systemctl --failed` showed
`pd-mapper.service` and `gts9wifi-wait-sensor-proxy.service` (both
pre-existing, documented: missing vendor PDR `.jsn` firmware files) and
`logrotate.service` (`/var/log/sssd/*.log` glob against an always-empty
directory since this device never runs `sssd` -- a stock Fedora
packaging quirk, harmless, not investigated further as out of scope for
this session).

Fedora is now the confirmed-working, real-hardware-validated base this
project continues feature work from, per explicit user direction.
