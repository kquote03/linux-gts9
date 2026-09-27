#!/usr/bin/env python3
"""Reuse a stopped disk capture, omit userdata, verify all remaining sectors.

The sda image is sparse with a deliberately MISSING userdata range. Never flash
this disk image wholesale. The abandoned partial capture is retained separately.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

old, out = map(Path, sys.argv[1:])
assert not out.exists()
os.umask(0o077)
out.mkdir(parents=True)
manifest = json.loads((old/'manifest.json').read_text())
adb = ['adb','-s',manifest['serial']]
def shell(cmd):
    return subprocess.check_output(adb+['shell',cmd],text=True).strip()
assert not any(l.startswith('/dev/block/') for l in shell('cat /proc/mounts').splitlines())
excluded = manifest['partitions']['sda34']
manifest['excluded'] = {'userdata': excluded}
manifest['scope'] = 'All exposed UFS sectors EXCEPT userdata; sda.img has an absent sparse userdata range.'
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'by-name.txt').write_text((old/'by-name.txt').read_text())
records = []
for disk,info in manifest['disks'].items():
    assert shell(f'blockdev --getro /dev/block/{disk}') == '1'
    ranges = [(0,info['bytes'])]
    if disk == 'sda':
        end = excluded['offset']+excluded['bytes']
        ranges = [(0,excluded['offset']),(end,info['bytes']-end)]
    path = out/f'{disk}.img.partial'
    with path.open('x+b') as target:
        target.truncate(info['bytes'])
        for offset,size in ranges:
            target.seek(offset)
            digest = hashlib.sha256()
            print(f'{disk}: preserving offset {offset}, {size} bytes',flush=True)
            if disk == 'sda' and offset == 0:
                source = (old/'sda.img.partial').open('rb')
                proc = None
            else:
                assert offset%4096 == size%4096 == 0
                proc = subprocess.Popen(adb+['exec-out',f'dd if=/dev/block/{disk} bs=4096 skip={offset//4096} count={size//4096} 2>/dev/null'],stdout=subprocess.PIPE)
                source = proc.stdout
            left = size
            while left:
                data = source.read(min(left,4*1024*1024))
                assert data, 'Short capture'
                target.write(data); digest.update(data); left -= len(data)
            source.close()
            if proc: assert proc.wait() == 0
            target.flush(); os.fsync(target.fileno())
            print(f'{disk}: checking independent device hash',flush=True)
            remote = shell(f'dd if=/dev/block/{disk} bs=4096 skip={offset//4096} count={size//4096} 2>/dev/null | sha256sum').split()[0]
            target.seek(offset)
            saved = hashlib.sha256(); left = size
            while left:
                data = target.read(min(left,4*1024*1024)); assert data
                saved.update(data); left -= len(data)
            assert remote == digest.hexdigest() == saved.hexdigest(), 'Hash mismatch'
            records.append({'disk':disk,'offset':offset,'bytes':size,'sha256':remote})
            print(f'{disk}: range VERIFIED',flush=True)
    path.rename(out/f'{disk}.img')
manifest['verified_ranges'] = records
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'VERIFIED.txt').write_text('All exposed UFS sectors EXCEPT userdata match independent device and saved-file hashes. USERDATA IS NOT BACKED UP. Never restore sda.img as a whole disk.\n')
(out/'README.txt').write_text(manifest['scope']+'\nThe old partial capture is incomplete and is NOT a userdata rollback image.\nUse manifest.json ranges and partition offsets for partition-only restoration.\n')
print('Backup excluding userdata VERIFIED',flush=True)
