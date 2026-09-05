#!/usr/bin/env bash
# Build a genuinely empty ramdisk (zero files, just the cpio EOF trailer).
#
# Needed for init_boot's ramdisk slot when a real rootfs (e.g. the
# Buildroot Weston rootfs) is too big for init_boot's fixed 8 MiB
# partition and has to go into vendor_boot's 96 MiB one instead (see
# docs/porting-log.md's Session 5 entry). ABL combines both ramdisks into
# one initramfs at boot (concatenated cpio archives, standard mainline
# behavior), so init_boot's slot can't just be left out -- but it also
# must not contain anything that could override a same-named path from
# vendor_boot's real rootfs, regardless of which archive gets
# concatenated first. An empty archive has nothing to override with,
# which is simpler and safer than trying to reason about concatenation
# order.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
mkdir -p "$outdir"
out="$outdir/empty-ramdisk.cpio.gz"

printf '' | cpio -o -H newc 2>/dev/null | gzip -9 > "$out"

ls -la "$out"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
