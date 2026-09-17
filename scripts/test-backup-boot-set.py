#!/usr/bin/env python3
"""Exercise binary backup validation with a fake recovery transport."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('backup-boot-set.sh')
FAKE_ADB = r'''#!/usr/bin/env python3
import hashlib, os, re, sys
args=sys.argv[1:]
if args[0]=='get-state':
 print(os.environ.get('MOCK_STATE','recovery')); sys.exit()
command=' '.join(args[1:])
if 'getprop ro.twrp.version' in command:
 print('3.7.0'); sys.exit()
match=re.search(r'/(boot|init_boot|vendor_boot|dtbo)\b',command)
if not match: raise SystemExit('unexpected mock command '+command)
part=match[1]; data=(part.encode()*1024)[:1024]
if args[0]=='exec-out':
 if '2>/dev/null' not in command: raise SystemExit('remote stderr not redirected')
 sys.stdout.buffer.write(data)
 if os.environ.get('MOCK_TRAILER'): sys.stdout.buffer.write(b'2+0 records out\n')
elif 'blockdev --getsize64' in command:
 print(1024)
elif 'sha256sum' in command:
 print(hashlib.sha256(data).hexdigest()+'  /dev/block/bootdevice/by-name/'+part)
elif 'for base in' in command:
 print('/dev/block/bootdevice/by-name/'+part)
else: raise SystemExit('unexpected mock command '+command)
'''


class BackupChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        adb = self.root / 'adb'
        adb.write_text(FAKE_ADB)
        adb.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'])
        self.output = self.root / 'backup'

    def run_backup(self, **environment):
        return subprocess.run(['bash', str(SCRIPT), str(self.output)],
                              env=dict(self.environment, **environment), capture_output=True, text=True)

    def test_exact_binary_backup_and_hashes(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / 'VERIFIED.txt').is_file())
        for part in ('boot', 'init_boot', 'vendor_boot', 'dtbo'):
            data = (self.output / (part + '.img')).read_bytes()
            self.assertEqual(data, (part.encode() * 1024)[:1024])
            self.assertIn(hashlib.sha256(data).hexdigest(), (self.output / 'SHA256SUMS').read_text())

    def test_appended_diagnostics_rejected(self):
        result = self.run_backup(MOCK_TRAILER='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('size mismatch', result.stderr)
        self.assertFalse((self.output / 'VERIFIED.txt').exists())
        self.assertTrue((self.output / 'boot.img.partial').exists())

    def test_booted_device_refused_before_output_creation(self):
        result = self.run_backup(MOCK_STATE='device')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_existing_backup_preserved(self):
        self.output.mkdir()
        original = self.output / 'boot.img'
        original.write_bytes(b'original')
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original.read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
