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
