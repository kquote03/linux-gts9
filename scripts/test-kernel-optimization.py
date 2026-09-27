#!/usr/bin/env python3
"""Focused enforcement regressions; run with Python's standard library."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify', ROOT / 'scripts/verify-kernel-fragments.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class ConfigTests(unittest.TestCase):
    def test_resolution_and_conflicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, first, second = [Path(tmp) / name for name in ['config', 'first', 'second']]
            config.write_text('CONFIG_A=y\n# CONFIG_B is not set\n')
            first.write_text('CONFIG_A=y\nCONFIG_B=n\n')
            self.assertEqual(verify.verify(config, [first]), [])
            second.write_text('CONFIG_A=m\nCONFIG_MISSING=y\n')
            self.assertEqual(len(verify.verify(config, [first, second])), 3)
            config.write_text('CONFIG_A=m\n# CONFIG_B is not set\n')
            self.assertEqual(len(verify.verify(config, [first])), 1)

    def test_ufs_rule_scope(self):
        rule = (ROOT / 'rootfs/overlay-common/usr/lib/udev/rules.d/61-gts9-ufs-scheduler.rules').read_text()
        for required in ['ENV{DEVTYPE}=="disk"', 'DRIVERS=="ufshcd-qcom"',
                         'PROGRAM="/usr/libexec/gts9-is-x716"', 'ATTR{queue/scheduler}="bfq"']:
            self.assertIn(required, rule)
        self.assertNotIn('KERNEL=="sd', rule)
        self.assertIn("grep -qx 'samsung,gts9-5g'", (ROOT / 'rootfs/overlay-common/usr/libexec/gts9-is-x716').read_text())


if __name__ == '__main__':
    unittest.main()
