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
