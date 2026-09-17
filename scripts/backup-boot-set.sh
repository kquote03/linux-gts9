#!/usr/bin/env bash
# Read-only TWRP backup. Binary exec-out must never include remote dd stderr.
# Usage: bash scripts/backup-boot-set.sh backups/<new-explicit-directory>
# ANDROID_SERIAL can select a device using adb's standard environment support.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: bash scripts/backup-boot-set.sh <new-output-directory>" >&2
    exit 2
fi
outdir=$1
if [ -e "$outdir" ] || [ -L "$outdir" ]; then
    echo "error: output directory already exists: $outdir" >&2
    exit 1
fi
for program in adb sha256sum stat tr mkdir dirname date mv; do
    command -v "$program" >/dev/null || {
        echo "error: required command unavailable: $program" >&2
        exit 1
    }
done
state=$(adb get-state | tr -d '\r')
if [ "$state" != recovery ]; then
    echo "error: device must already be in TWRP recovery (state: $state)" >&2
    exit 1
fi
twrp=$(adb shell getprop ro.twrp.version | tr -d '\r')
if [ -z "$twrp" ]; then
    echo "error: recovery did not identify itself as TWRP" >&2
    exit 1
fi

partitions=(boot init_boot vendor_boot dtbo)
declare -A device_paths expected_sizes expected_hashes
for partition in "${partitions[@]}"; do
    device_path=$(adb shell "for base in /dev/block/bootdevice/by-name /dev/block/by-name; do if [ -b \"\$base/$partition\" ]; then echo \"\$base/$partition\"; exit 0; fi; done; exit 1" | tr -d '\r')
    case "$device_path" in
        /dev/block/bootdevice/by-name/"$partition"|/dev/block/by-name/"$partition") ;;
        *) echo "error: could not resolve block device: $partition" >&2; exit 1 ;;
    esac
    size=$(adb shell "blockdev --getsize64 '$device_path'" | tr -d '\r')
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size <= 0 || size % 512 != 0 )); then
        echo "error: invalid block-device size for $partition: $size" >&2
        exit 1
    fi
    remote_hash=$(adb shell "sha256sum '$device_path'" | tr -d '\r')
    remote_hash=${remote_hash%% *}
    if [[ ! "$remote_hash" =~ ^[0-9a-f]{64}$ ]]; then
        echo "error: invalid remote SHA256 for $partition" >&2
        exit 1
    fi
    device_paths[$partition]=$device_path
    expected_sizes[$partition]=$size
    expected_hashes[$partition]=$remote_hash
done

mkdir -p -- "$(dirname -- "$outdir")"
mkdir -- "$outdir"
printf 'partition\tdevice\tsize_bytes\tsha256\n' > "$outdir/PARTITIONS.tsv"
printf 'TWRP: %s\nCaptured UTC: %s\n' "$twrp" "$(date -u +%FT%TZ)" > "$outdir/PROVENANCE.txt"
for partition in "${partitions[@]}"; do
    device_path=${device_paths[$partition]}
    echo "Reading $partition (${expected_sizes[$partition]} bytes)"
    # adb exec-out may merge the remote shell's stderr with stdout. Redirect
    # stderr on the DEVICE, not merely the host, to keep the stream binary.
    adb exec-out "dd if='$device_path' bs=1048576 2>/dev/null" > "$outdir/$partition.img.partial"
    actual_size=$(stat -c %s -- "$outdir/$partition.img.partial")
    if [ "$actual_size" != "${expected_sizes[$partition]}" ]; then
        echo "error: $partition size mismatch: expected ${expected_sizes[$partition]}, got $actual_size; partial evidence retained" >&2
        exit 1
    fi
    local_hash=$(sha256sum -- "$outdir/$partition.img.partial")
    local_hash=${local_hash%% *}
    after_hash=$(adb shell "sha256sum '$device_path'" | tr -d '\r')
    after_hash=${after_hash%% *}
    if [ "$local_hash" != "${expected_hashes[$partition]}" ] || [ "$after_hash" != "$local_hash" ]; then
        echo "error: $partition remote/local SHA256 mismatch; partial evidence retained" >&2
        exit 1
    fi
    mv -- "$outdir/$partition.img.partial" "$outdir/$partition.img"
    printf '%s\t%s\t%s\t%s\n' "$partition" "$device_path" "$actual_size" "$local_hash" >> "$outdir/PARTITIONS.tsv"
    printf '%s  %s.img\n' "$local_hash" "$partition" >> "$outdir/SHA256SUMS"
done
(cd -- "$outdir" && sha256sum -c SHA256SUMS)
printf 'All four exact-sized partition images match remote hashes before and after capture.\n' > "$outdir/VERIFIED.txt"
echo "Verified boot-set backup: $outdir"
