#!/usr/bin/env python3
"""Install to the existing userdata; verify every byte outside the allowlist.

Usage: install-internal-fedora.py BACKUP STAGE [--execute]
Without --execute, prepares and validates the preservation manifest only.
Requires a verified full backup or an explicitly userdata-excluded backup.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib

ALLOWED = {'userdata': 'sda34', 'init_boot': 'sda22', 'vendor_boot': 'sda24'}

def hash_range(path, offset, size):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        stream.seek(offset)
        while size:
            data = stream.read(min(size, 4*1024*1024))
            if not data:
                raise RuntimeError(f'Short read: {path}')
            digest.update(data)
            size -= len(data)
    return digest.hexdigest()

def gpt(path, sector, size):
    """Validate both GPT copies and return exact partition identifiers."""
    copies = []
    with path.open('rb') as stream:
        for lba in (1, size // sector - 1):
            stream.seek(lba * sector)
            raw = stream.read(sector)
            header = struct.unpack_from('<8sIIIIQQQQ16sQIII', raw)
            magic, _, length, crc, _, current, alternate, first, last, guid, table, count, width, tablecrc = header
            assert magic == b'EFI PART' and current == lba
            assert 92 <= length <= sector and width >= 128 and count * width < 16*1024*1024
            assert alternate == (size // sector - 1 if lba == 1 else 1)
            check = bytearray(raw[:length]); check[16:20] = bytes(4)
            assert zlib.crc32(check) == crc, 'GPT header CRC mismatch'
            stream.seek(table * sector)
            entries = stream.read(count * width)
            assert zlib.crc32(entries) == tablecrc, 'GPT entries CRC mismatch'
            parts = []
            for i in range(count):
                entry = entries[i*width:(i+1)*width]
                if entry[:16] == bytes(16):
                    continue
                start, end, attributes = struct.unpack_from('<QQQ', entry, 32)
                parts.append({'number': i+1, 'name': entry[56:128].decode('utf-16-le').rstrip('\0'),
                              'offset': start*sector, 'bytes': (end-start+1)*sector,
                              'type_guid_hex': entry[:16].hex(), 'guid_hex': entry[16:32].hex(),
                              'attributes': attributes})
            copies.append((guid.hex(), first, last, parts))
    assert copies[0] == copies[1], 'GPT copies differ'
    return copies[0][3]

def main():
    backup, stage = map(Path, sys.argv[1:3])
    execute = sys.argv[3:] == ['--execute']
    assert sys.argv[3:] in ([], ['--execute'])
    assert (backup / 'VERIFIED.txt').is_file()
    manifest = json.loads((backup / 'manifest.json').read_text())
    assert manifest['serial'] == 'R52Y60DXCHZ'
    if 'excluded' in manifest:
        assert manifest['excluded'] == {'userdata': manifest['partitions']['sda34']}
        print('Userdata backup was explicitly waived; Android data has no complete rollback image.', flush=True)
    adb = ['adb', '-s', manifest['serial']]
    def shell(cmd):
        return subprocess.check_output(adb + ['shell', cmd], text=True).strip()
    layout = {}
    protected = []
    for disk, info in manifest['disks'].items():
        source = backup / f'{disk}.img'
        assert source.stat().st_size == info['bytes']
        parts = gpt(source, info['sector_bytes'], info['bytes'])
        layout[disk] = parts
        for part in parts:
            node = disk + str(part['number'])
            recorded = manifest['partitions'][node]
            assert (part['offset'], part['bytes']) == (recorded['offset'], recorded['bytes'])
            if part['name'] in ALLOWED:
                assert node == ALLOWED[part['name']]
        skipped = sorted((p['offset'], p['offset']+p['bytes']) for p in parts if p['name'] in ALLOWED)
        cursor = 0
        for start, end in skipped + [(info['bytes'], info['bytes'])]:
            if start > cursor:
                protected.append({'disk':disk, 'offset':cursor, 'bytes':start-cursor,
                                  'sha256': hash_range(source,cursor,start-cursor)})
            cursor = end
    images = {'userdata': stage/'rootfs.img', 'init_boot':stage/'init_boot.img', 'vendor_boot':stage/'vendor_boot.img'}
    candidates = {}
    for name, image in images.items():
        limit = manifest['partitions'][ALLOWED[name]]['bytes']
        size = image.stat().st_size
        assert 0 < size <= limit and size % 4096 == 0
        if name != 'userdata':
            assert size == limit
        candidates[name] = {'bytes':size, 'mtime_ns':image.stat().st_mtime_ns,
                            'sha256':hash_range(image,0,size)}
    report = {'gpt':layout, 'protected_ranges':protected, 'candidates':candidates}
    (stage/'preservation.json').write_text(json.dumps(report,indent=2)+'\n')
    if not execute:
        print('Prepared preservation manifest; no device writes.'); return
    assert shell('getprop ro.product.model') == 'SM-X716B'
    assert shell('getprop ro.twrp.version')
    print('Battery: '+shell('cat /sys/class/power_supply/battery/capacity')+'% (user waived charge threshold)', flush=True)
    def unmounted():
        assert not any(l.startswith('/dev/block/') for l in shell('cat /proc/mounts').splitlines())
    unmounted()
    for disk, info in manifest['disks'].items():
        assert int(shell(f'blockdev --getsize64 /dev/block/{disk}')) == info['bytes']
    for name,node in ALLOWED.items():
        assert shell(f'readlink -f /dev/block/by-name/{name}') == f'/dev/block/{node}'
        assert int(shell(f'blockdev --getsize64 /dev/block/{node}')) == manifest['partitions'][node]['bytes']
        assert int(shell(f'cat /sys/class/block/{node}/start'))*512 == manifest['partitions'][node]['offset']
    def verify_protected(phase):
        for r in protected:
            assert r['offset']%4096 == r['bytes']%4096 == 0
            print(f'{phase}: checking {r["disk"]} offset {r["offset"]}, {r["bytes"]} protected bytes',flush=True)
            result = shell(f'dd if=/dev/block/{r["disk"]} bs=4096 skip={r["offset"]//4096} count={r["bytes"]//4096} 2>/dev/null | sha256sum').split()[0]
            assert result == r['sha256'], 'PROTECTED STORAGE MISMATCH: '+str(r)
    verify_protected('Before installation')
    shell('blockdev --setrw /dev/block/sda')
    for node in manifest['partitions']:
        shell(f'blockdev --setro /dev/block/{node}')
    for name,image in images.items():
        unmounted()
        node = ALLOWED[name]
        assert image.stat().st_size == candidates[name]['bytes']
        assert image.stat().st_mtime_ns == candidates[name]['mtime_ns']
        print(f'Writing ONLY {name} ({node})',flush=True)
        shell(f'blockdev --setrw /dev/block/{node}')
        try:
            # Compress only in transit to shorten USB transfer; verification
            # below still hashes the exact uncompressed image bytes on disk.
            compressor = subprocess.Popen(['gzip','-1','-c',str(image)],stdout=subprocess.PIPE)
            try:
                subprocess.run(adb+['shell','-T',f'set -o pipefail; gzip -dc | dd of=/dev/block/{node} bs=64k'],stdin=compressor.stdout,check=True)
                compressor.stdout.close()
                assert compressor.wait() == 0, 'Image compression failed'
            finally:
                if compressor.poll() is None:
                    compressor.terminate(); compressor.wait()
            shell('sync')
            result = shell(f'dd if=/dev/block/{node} bs=4096 count={candidates[name]["bytes"]//4096} 2>/dev/null | sha256sum').split()[0]
            assert result == candidates[name]['sha256'], f'{name} READBACK MISMATCH'
        finally:
            shell(f'blockdev --setro /dev/block/{node}')
        print(f'{name}: readback VERIFIED',flush=True)
    shell('blockdev --setro /dev/block/sda')
    unmounted()
    verify_protected('After installation')
    (stage/'INSTALL-VERIFIED.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Installation verified. GPTs and every byte outside the three allowed partitions are unchanged. No reboot issued.',flush=True)

if __name__ == '__main__':
    main()
