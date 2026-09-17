#!/usr/bin/env python3
"""Validate the decoder against locally extracted stock descriptors.

Device blobs are intentionally not test fixtures committed to Git. Tests skip
when the read-only stock extraction is unavailable.
"""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("decoder", Path(__file__).with_name("decode-stock-camera.py"))
decoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decoder)
BASE = REPO / "work/camera-stock-2026-09-16/camera/camera"
REAR = BASE / "com.samsung.sensormodule.0_hynix_hi1337.bin"
TABLES = REPO / "kernel/drivers/hi1337_gts9_tables.h"


@unittest.skipUnless(REAR.exists(), "needs read-only stock camera extraction")
class DescriptorChecks(unittest.TestCase):
    def modified(self, change, repair_crc=False):
        blob = bytearray(REAR.read_bytes())
        change(blob)
        if repair_crc:
            struct.pack_into("<I", blob, len(blob) - 4, zlib.crc32(blob[:-4]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "descriptor.bin"
            path.write_bytes(blob)
            return decoder.decode(path)

    def test_rear_sequences_match_and_phy_is_dphy(self):
        report = decoder.decode(REAR, TABLES)
        mode = report["resolution_modes"][0]
        self.assertEqual((mode["streams"][0]["width"], mode["streams"][0]["height"]), (4128, 3096))
        self.assertEqual((mode["lane_count"], mode["settle_time_ns"], mode["is_3_phase"]), (4, 28, 0))
        self.assertEqual(mode["table_comparison"]["exact_register_sequence_matches"], ["hi1337_rear_4128x3096_regs"])
        self.assertEqual(report["init_arrays"][0]["table_comparison"]["exact_register_sequence_matches"], ["hi1337_global_regs"])

    def test_front_descriptors_have_different_modes(self):
        for name, dimension in (("1_hynix_hi1337_front", (2032, 1524)),
                                ("12_hynix_hi1337_front_full", (4000, 3000))):
            report = decoder.decode(BASE / f"com.samsung.sensormodule.{name}.bin", TABLES)
            mode = report["resolution_modes"][0]
            self.assertEqual((mode["streams"][0]["width"], mode["streams"][0]["height"]), dimension)
            self.assertEqual(report["phy_mode"], "D-PHY")
            expected = ["hi1337_front_2032x1524_regs"] if name.startswith("1_") else []
            self.assertEqual(mode["table_comparison"]["exact_register_sequence_matches"], expected)

    def test_corrupt_crc_rejected(self):
        with self.assertRaisesRegex(ValueError, "CRC32"):
            self.modified(lambda blob: blob.__setitem__(500, blob[500] ^ 1))

    def test_unknown_version_rejected_even_with_valid_crc(self):
        with self.assertRaisesRegex(ValueError, "parser version"):
            self.modified(lambda blob: blob.__setitem__(40, ord("X")), repair_crc=True)

    def test_bad_reference_rejected_even_with_valid_crc(self):
        def change(blob):
            data_offset = struct.unpack_from("<I", blob, 184)[0]
            struct.pack_into("<I", blob, data_offset + 16, 0xFFFFFFFF)
        with self.assertRaisesRegex(ValueError, "sensorName node reference"):
            self.modified(change, repair_crc=True)


if __name__ == "__main__":
    unittest.main()
