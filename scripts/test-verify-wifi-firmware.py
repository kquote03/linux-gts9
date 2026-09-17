#!/usr/bin/env python3
"""Exercise packaging failures that previously shipped mixed firmware."""
import gzip
import importlib.util
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-wifi-firmware.py")
spec = importlib.util.spec_from_file_location("verify_wifi", SCRIPT)
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)


def newc(files):
    data = bytearray()
    for name, payload in [*files.items(), ("TRAILER!!!", b"")]:
        name = name.encode() + b"\0"
        fields = [1, 0o100644, 0, 0, 1, 0, len(payload), 0, 0, 0, 0, len(name), 0]
        data.extend(b"070701" + b"".join(f"{n:08x}".encode() for n in fields))
        data.extend(name)
        data.extend(b"\0" * (-len(data) % 4))
        data.extend(payload)
        data.extend(b"\0" * (-len(data) % 4))
    return bytes(data)


class FirmwareChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.reference = self.root / "reference"
        (self.reference / wifi.WIFI).mkdir(parents=True)
        self.files = {name: name.encode() for name in wifi.FILES}
        for name, payload in self.files.items():
            (self.reference / wifi.WIFI / name).write_bytes(payload)

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--reference",
                               str(self.reference), *map(str, args)],
                              capture_output=True, text=True)

    def archive(self, overrides=None):
        files = {f"./lib/firmware/{wifi.WIFI}/{name}": payload
                 for name, payload in self.files.items()}
        files.update(overrides or {})
        path = self.root / "initramfs.gz"
        path.write_bytes(gzip.compress(newc(files)))
        return path

    def test_matching_directory_and_archive(self):
        result = self.run_check("--firmware-dir", self.reference,
                                "--initramfs", self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stale_archive_rejected(self):
        archive = self.archive({f"./lib/firmware/{wifi.WIFI}/m3.bin": b"old"})
        result = self.run_check("--initramfs", archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("m3.bin", result.stderr)

    def test_api2_override_rejected(self):
        (self.reference / wifi.WIFI / "firmware-2.bin.zst").write_bytes(b"override")
        self.assertNotEqual(self.run_check("--firmware-dir", self.reference).returncode, 0)

    def test_conflicting_usr_copy_rejected(self):
        archive = self.archive({f"./usr/lib/firmware/{wifi.WIFI}/amss.bin": b"old"})
        self.assertNotEqual(self.run_check("--initramfs", archive).returncode, 0)

    def test_missing_file_rejected(self):
        (self.reference / wifi.WIFI / "m3.bin").unlink()
        self.assertNotEqual(self.run_check("--firmware-dir", self.reference).returncode, 0)

    def test_truncated_archive_rejected(self):
        path = self.root / "truncated"
        path.write_bytes(newc({"x": b"payload"})[:120])
        self.assertNotEqual(self.run_check("--initramfs", path).returncode, 0)

    def test_empty_bringup_requires_explicit_flag(self):
        path = self.root / "bringup"
        path.write_bytes(newc({"init": b"#!/bin/sh"}))
        self.assertNotEqual(self.run_check("--initramfs", path).returncode, 0)
        self.assertEqual(self.run_check("--allow-no-wifi", "--initramfs", path).returncode, 0)

    @unittest.skipUnless(shutil.which("mke2fs") and shutil.which("debugfs"), "needs e2fsprogs")
    def test_deployment_reads_image_contents(self):
        root = self.root / "rootfs"
        firmware = root / "usr/lib/firmware" / wifi.WIFI
        firmware.mkdir(parents=True)
        (root / "usr/lib/os-release").write_text("ID=fedora\n")
        for name, content in self.files.items():
            (firmware / name).write_bytes(content)
        image = self.root / "rootfs.img"
        subprocess.run(["mke2fs", "-q", "-t", "ext4", "-d", str(root), str(image), "16M"],
                       check=True, capture_output=True)
        result = self.run_check("--fedora-image", image)
        self.assertEqual(result.returncode, 0, result.stderr)
        # Change the actual image, leaving the source directory correct.
        subprocess.run(["debugfs", "-w", "-R", f"rm /usr/lib/firmware/{wifi.WIFI}/m3.bin", str(image)],
                       check=True, capture_output=True)
        result = self.run_check("--fedora-image", image)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("m3.bin", result.stderr)


if __name__ == "__main__":
    unittest.main()
