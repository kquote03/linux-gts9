#!/usr/bin/env python3
"""Reject stale/mixed WCN6855 sets before packaging a rootfs or boot bundle.

Compare against the selected committed firmware overlay (Samsung by default;
fetch-ath11k-firmware.sh can select community for a controlled A/B). Inputs are
firmware directories or gzip/legacy-LZ4/newc initramfs archives. Never extract
archive paths onto the host filesystem.
"""
import argparse
import gzip
import hashlib
from pathlib import Path
import stat
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
WIFI = Path("ath11k/WCN6855/hw2.1")
FILES = ("amss.bin", "board-2.bin", "m3.bin", "regdb.bin")


def archive_files(path):
    data = path.read_bytes()
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    elif data.startswith((b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18")):
        data = subprocess.check_output(["lz4", "-dc", str(path)])
    entries = {}
    offset = 0
    trailers = 0
    while offset < len(data):
        if data[offset] == 0:
            offset += 1
            continue
        header = data[offset:offset + 110]
        if len(header) != 110 or header[:6] not in (b"070701", b"070702"):
            raise ValueError(f"{path}: invalid newc header at {offset}")
        fields = [int(header[i:i + 8], 16) for i in range(6, 110, 8)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        start = offset + 110
        end = start + namesize
        if namesize < 1 or end > len(data) or data[end - 1] != 0:
            raise ValueError(f"{path}: truncated archive name")
        name = data[start:end - 1].decode().removeprefix("./")
        start = (end + 3) & ~3
        end = start + size
        if end > len(data):
            raise ValueError(f"{path}: truncated archive data")
        if name == "TRAILER!!!":
            trailers += 1
        else:
            entries[name] = (mode, data[start:end])
        offset = (end + 3) & ~3
    if not trailers:
        raise ValueError(f"{path}: missing archive trailer")
    return entries


def verify(actual, expected, label):
    for name, content in expected.items():
        if actual.get(name) != content:
            raise ValueError(f"{label}: missing or mismatched {WIFI / name}; "
                             "restage the complete selected WiFi set and rebuild both images")
    print(f"{label}: matched WiFi set ({hashlib.sha256(expected['amss.bin']).hexdigest()[:16]})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path,
                        default=REPO / "buildroot/firmware-overlay/lib/firmware")
    parser.add_argument("--firmware-dir", type=Path, action="append", default=[])
    parser.add_argument("--initramfs", type=Path, action="append", default=[])
    parser.add_argument("--fedora-image", type=Path, action="append", default=[],
                        help="verify firmware inside a Fedora ext4 image before deployment; other distros are unchanged")
    parser.add_argument("--allow-no-wifi", action="store_true",
                        help="allow a bring-up archive containing no WiFi firmware")
    args = parser.parse_args()
    if not args.firmware_dir and not args.initramfs and not args.fedora_image:
        parser.error("provide --firmware-dir, --initramfs, or --fedora-image")
    expected = {name: (args.reference / WIFI / name).read_bytes() for name in FILES}
    if not all(expected.values()):
        raise ValueError("selected firmware overlay is incomplete")
    for path in args.fedora_image:
        if not path.is_file():
            raise ValueError(f"{path}: image missing")

        def debugfs(command):
            result = subprocess.run(["debugfs", "-R", command, str(path)],
                                    capture_output=True, check=True)
            return result.stdout

        # These builders use a real /usr/lib/firmware tree. NixOS uses
        # store symlinks and its separate firmware derivation; don't impose
        # Fedora's layout on that deployment path.
        release = debugfs("cat /usr/lib/os-release")
        if b"ID=fedora" not in release.splitlines() and b'ID="fedora"' not in release.splitlines():
            print(f"{path}: not a Fedora /usr image; Fedora firmware check not applicable")
            continue
        directory = f"/usr/lib/firmware/{WIFI}"
        for suffix in ("", ".xz", ".zst"):
            if b"Inode:" in debugfs(f"stat {directory}/firmware-2.bin{suffix}"):
                raise ValueError(f"{path}: firmware-2.bin overrides the selected AMSS/M3")
        verify({name: debugfs(f"cat {directory}/{name}") for name in FILES}, expected, path)
    for root in args.firmware_dir:
        directory = root / WIFI
        if any(directory.glob("firmware-2.bin*")):
            raise ValueError(f"{directory}: firmware-2.bin overrides the selected AMSS/M3")
        verify({name: (directory / name).read_bytes() for name in FILES}, expected, root)
    for path in args.initramfs:
        entries = archive_files(path)
        prefixes = [str(Path(base) / WIFI) + "/" for base in ("lib/firmware", "usr/lib/firmware")]
        found = {name: value for name, value in entries.items()
                 if any(name.startswith(prefix) for prefix in prefixes)}
        if not found and args.allow_no_wifi:
            print(f"{path}: bring-up archive, no WiFi firmware")
            continue
        actual = {}
        for name, (mode, content) in found.items():
            leaf = Path(name).name
            if leaf.startswith("firmware-2.bin"):
                raise ValueError(f"{path}: {name} overrides the selected AMSS/M3")
            if leaf in FILES:
                if not stat.S_ISREG(mode):
                    raise ValueError(f"{path}: expected regular firmware file: {name}")
                if leaf in actual and actual[leaf] != content:
                    raise ValueError(f"{path}: conflicting /lib and /usr/lib copies of {leaf}")
                actual[leaf] = content
        verify(actual, expected, path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"WiFi firmware verification failed: {error}")
