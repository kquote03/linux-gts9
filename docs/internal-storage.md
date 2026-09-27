# Internal Fedora installation

The internal target is the existing `userdata` partition, not a new partition.
No internal partition may be resized, moved, created, or deleted. The installation
write allowlist is **userdata, init_boot, vendor_boot**; `vendor_boot` is not the
Android `vendor` filesystem within `super`. `boot`, `dtbo`, recovery, Android
system/vendor, and all device-specific partitions remain protected.

## Backup before installation

With the SM-X716B in TWRP, unmount all internal block filesystems (including the
`/sdcard` bind mount, `/data`, and `/cache`). Then run:

```sh
python scripts/backup-internal-storage.py R52Y60DXCHZ backups/<new-directory>
```

This captures **all six complete exposed UFS logical units**, including both GPT
copies, unused regions, Android userdata and encryption metadata. It temporarily
sets runtime block read-only flags to prevent recovery writes. Each image must
have its exact device size and match independent device and saved-file SHA-256
reads before `VERIFIED.txt` is created. Never install from an incomplete capture.
The 128 GB unit needs approximately 119 GiB of host backup capacity.

`manifest.json` records 512-byte sysfs offsets as byte offsets, alongside the
actual 4096-byte logical sector size. Do not confuse these two sector units.
`by-name.txt` records partition aliases. Private backup data stays out of Git.
RPMB and inaccessible security-hardware state are not ordinary disk sectors;
raw images do not guarantee future Android decryption or dual-boot compatibility.

### September 26 scope revision

During capture the user explicitly requested skipping `/data` to finish sooner,
and waived the planned battery threshold. `finish-backup-without-userdata.py`
reuses the already captured prefix, captures the trailing GPT and remaining LUs,
and verifies every range outside userdata independently against the device.
`backups/2026-09-26-internal-excluding-userdata/` is the resulting backup location.
Its `sda.img` has a deliberately absent, sparse userdata range: **never restore it
as a whole disk or extract userdata from it for restoration**. The original
partial capture is retained but is not a complete userdata backup. Android data
cannot be rolled back from this backup after installation.

## Build and preservation checks

`nix develop --command bash scripts/build-internal-fedora.sh` uses the saved
September 26 Fedora GNOME tarball as a fresh userspace base in a new
`out/internal-fedora/`. It stages the current kernel modules and applies the
internal overlay **last**, replacing the generic partition-growing helper with
filesystem-only growth. The installed kernel payload must match that build.

The root filesystem and fstab use `X716B_INTERNAL`. Build the initramfs with
`REAL_ROOT_LABEL=X716B_INTERNAL REAL_ROOT_LABEL_ONLY=1`; this disables device-name
fallback in both the normal root lookup and charging logger. A still-inserted
microSD carrying `X716B_ROOT` therefore cannot win root selection.

The internal overlay also prevents existing userspace from writing protected
storage: stock persist and DSP mount with `ro,noload`; writable sensor calibration
is copied to userdata and bind-mounted for HexagonFS; automatic Bluetooth boot
image provisioning is disabled. The deployed DTBs already carry the native
Bluetooth address. These overrides are required, not optional optimizations.

Take a fresh boot-set backup with `scripts/backup-boot-set.sh`, then run:

```sh
nix develop --command python3 scripts/repack-internal-ramdisks.py \
  out/internal-boot-current out/internal-fedora
python scripts/install-internal-fedora.py \
  backups/<verified-directory> out/internal-fedora
```

Repacking retains the deployed header fields and DTB, replaces the two ramdisks,
updates the informational root argument, and removes temporary `gts9.debugnet`
telnet access. The installer validates both GPT CRCs, the exact partition map,
and candidate sizes, then saves a preservation manifest. Without `--execute`, it
does not write to the tablet.

Append `--execute` to install (the user explicitly waived the charge threshold).
The execution path
requires TWRP and unmounted filesystems, verifies every byte outside the three
allowed partitions before and after writing, and verifies each candidate's
readback. It does not reboot. Never substitute the deployment script's `sd`
target: that target explicitly repartitions its selected disk.

After a verified installation, boot with `adb reboot system`. Check that `/`
uses internal userdata, the filesystem fills that unchanged partition, and the
desktop, USB SSH, Wi-Fi, and charging-mode root selection work. First-boot growth
uses Fedora's current `resize2fs`, not TWRP's incompatible older e2fsprogs.

## Recovery

Keep the backup and its manifest indefinitely. If installation fails, return
to TWRP and restore **only affected allowlisted partitions**. For each partition,
first confirm it is not listed in `excluded`, then stream precisely `offset`
through `offset + bytes` from its containing disk image
in `manifest.json` into its existing by-name partition, then verify the resulting
partition hash against that same backup range. Userdata is large: stream the range
directly rather than requiring a second 105 GiB host file. Restore the saved
ramdisks with it if returning to the previous boot selection.

Do not flash a full `sda.img` or restore GPTs: the partition layout has not changed.
Restoring Android userdata alone does not restore an Android boot chain; retain
the project's older stock boot backups for that separate future task.

## September 26 result

The installation booted successfully from sda34 with the microSD inserted.
Filesystem growth, GNOME, SSH, Wi-Fi, Bluetooth, and read-only calibration mounts
were verified. All 85 partition boundaries and both GPT copies on each UFS LU
match the backup after boot. Final evidence is in `out/internal-fedora/`:
`INSTALL-VERIFIED.json` records the base-image readbacks and protected ranges;
`POSTINSTALL-OVERLAY.json` records the subsequent userdata-only file overrides;
`FINAL-PROTECTED-VERIFIED.txt` records the repeated preservation check;
`POSTBOOT-PARTITIONS.txt`, `POSTBOOT-GPT-SHA256.txt`, and `POSTBOOT-SERVICES.txt`
record the live checks. The staged rootfs image also includes the final overrides.
