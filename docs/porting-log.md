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
