#!/usr/bin/env bash
# Build a minimal debug-only initramfs for early bring-up: a static
# busybox + a /init that just proves userspace hand-off worked, then loops
# forever (never exits -- an init that exits panics the kernel). This is
# NOT the real Ubuntu rootfs (that's Phase 4) -- its only job is to give an
# unambiguous "the kernel reached userspace" signal for sec-log capture.
#
# Must run inside `nix-shell` (shell.nix), which exports
# BUSYBOX_AARCH64_STATIC pointing at a fully static aarch64 busybox (the
# default dynamically-linked one references a Nix store path as its ELF
# interpreter, which won't exist on-device).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir=${BUILD_OUT:-$repo_root/out}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ -z "${BUSYBOX_AARCH64_STATIC:-}" ]; then
	echo "BUSYBOX_AARCH64_STATIC not set -- run this inside nix-shell" >&2
	exit 1
fi

echo "== staging ramdisk contents =="
mkdir -p "$workdir"/{bin,sbin,proc,sys,dev,tmp}
cp "$BUSYBOX_AARCH64_STATIC" "$workdir/bin/busybox"

for applet in sh mount cat echo ls dmesg sleep switch_root; do
	ln -sf busybox "$workdir/bin/$applet"
done

cat > "$workdir/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "=== linux-tabs9-port bring-up ramdisk: userspace reached ==="
echo "=== /init running as PID $$, looping forever (this is not a crash) ==="
while true; do
	/bin/busybox sleep 3600
done
EOF
chmod +x "$workdir/init"

mkdir -p "$outdir"
out="$outdir/bringup-ramdisk.cpio.gz"

echo "== building $out =="
( cd "$workdir" && find . | cpio -o -H newc ) | gzip -9 > "$out"

ls -la "$out"
echo "sha256: $(sha256sum "$out" | cut -d' ' -f1)"
