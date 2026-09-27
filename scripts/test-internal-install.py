#!/usr/bin/env python3
"""Offline regression checks for internal-install preservation guards."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-internal-fedora.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class GPTChecks(unittest.TestCase):
    def make_disk(self, path):
        sector, sectors = 4096, 256
        image = bytearray(sector * sectors)
        entries = bytearray(128 * 128)
        entries[:16] = b'T' * 16
        entries[16:32] = b'U' * 16
        struct.pack_into('<QQQ', entries, 32, 8, 240, 0)
        name = 'userdata'.encode('utf-16-le')
        entries[56:56+len(name)] = name
        for lba, alternate, table in ((1,255,2),(255,1,251)):
            header = bytearray(struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART',65536,92,0,0,lba,alternate,6,250,b'D'*16,table,128,128,zlib.crc32(entries)))
            struct.pack_into('<I', header, 16, zlib.crc32(header))
            image[lba*sector:lba*sector+92] = header
            image[table*sector:table*sector+len(entries)] = entries
        path.write_bytes(image)
        return image

    def test_four_k_sector_gpt_and_exact_bounds(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'disk'; image = self.make_disk(p)
            parts = installer.gpt(p,4096,len(image))
            self.assertEqual(parts[0]['name'],'userdata')
            self.assertEqual(parts[0]['offset'],8*4096)
            self.assertEqual(parts[0]['bytes'],233*4096)

    def test_corrupt_backup_gpt_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'disk'; image = self.make_disk(p)
            image[255*4096+24] ^= 1; p.write_bytes(image)
            with self.assertRaises(AssertionError): installer.gpt(p,4096,len(image))

    def test_corrupt_partition_table_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'disk'; image = self.make_disk(p)
            image[2*4096+32] ^= 1; p.write_bytes(image)
            with self.assertRaises(AssertionError): installer.gpt(p,4096,len(image))

    def test_short_backup_read_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'disk'; p.write_bytes(b'short')
            with self.assertRaises(RuntimeError): installer.hash_range(p,0,6)

    def test_write_allowlist_is_exact(self):
        self.assertEqual(installer.ALLOWED,{'userdata':'sda34','init_boot':'sda22','vendor_boot':'sda24'})

if __name__ == '__main__': unittest.main()
