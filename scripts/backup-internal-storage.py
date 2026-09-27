#!/usr/bin/env python3
"""Capture every exposed UFS LU from the X716B in quiescent TWRP.

Unmount internal filesystems before invoking. Sets runtime block read-only
flags, never writes disk contents. Output must be a new directory.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

serial, destination = sys.argv[1:]
adb = ['adb', '-s', serial]

def shell(command):
    return subprocess.check_output(adb + ['shell', command], text=True).strip()

def unmounted():
    mounts = shell('cat /proc/mounts')
    if any(line.startswith('/dev/block/') for line in mounts.splitlines()):
        raise RuntimeError('Block filesystem still mounted; refusing capture')

assert shell('getprop ro.product.model') == 'SM-X716B'
assert shell('getprop ro.twrp.version')
unmounted()
out = Path(destination)
if out.exists():
    raise RuntimeError('Backup directory already exists')
os.umask(0o077)
out.mkdir(parents=True)
manifest = {'serial': serial, 'captured_utc': time.strftime('%FT%TZ', time.gmtime()),
            'twrp': shell('getprop ro.twrp.version'), 'disks': {}, 'partitions': {}}
names = shell('ls -l /dev/block/by-name')
(out / 'by-name.txt').write_text(names + '\n')
for disk in ('sda', 'sdb', 'sdc', 'sdd', 'sde', 'sdf'):
    size = int(shell(f'blockdev --getsize64 /dev/block/{disk}'))
    sector = int(shell(f'cat /sys/class/block/{disk}/queue/logical_block_size'))
    manifest['disks'][disk] = {'bytes': size, 'sector_bytes': sector}
    nodes = shell(f'ls /sys/class/block | grep "^{disk}[0-9]*$"').splitlines()
    for node in nodes:
        shell(f'blockdev --setro /dev/block/{node}')
        assert shell(f'blockdev --getro /dev/block/{node}') == '1'
        if node != disk:
            start, sectors = shell(f'cat /sys/class/block/{node}/start /sys/class/block/{node}/size').split()
            manifest['partitions'][node] = {'disk': disk, 'offset': int(start)*512, 'bytes': int(sectors)*512}
total = sum(d['bytes'] for d in manifest['disks'].values())
assert shutil.disk_usage(out).free > total + 2*1024**3, 'Insufficient backup space'
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
for disk, info in manifest['disks'].items():
    unmounted()
    print(f'Capturing {disk}: {info["bytes"]} bytes', flush=True)
    partial = out / f'{disk}.img.partial'
    digest = hashlib.sha256()
    count = 0
    last_report = time.monotonic()
    proc = subprocess.Popen(adb + ['exec-out', f'dd if=/dev/block/{disk} bs=1048576 2>/dev/null'], stdout=subprocess.PIPE)
    with partial.open('xb') as target:
        while chunk := proc.stdout.read(4*1024*1024):
            target.write(chunk)
            digest.update(chunk)
            count += len(chunk)
            if time.monotonic() - last_report > 30:
                print(f'{disk}: {count / 1024**3:.2f} GiB / {info["bytes"] / 1024**3:.2f} GiB', flush=True)
                last_report = time.monotonic()
        target.flush()
        os.fsync(target.fileno())
    assert proc.wait() == 0
    assert count == info['bytes'], (disk, count, info['bytes'])
    print(f'{disk}: verifying independent device SHA256', flush=True)
    remote = shell(f'sha256sum /dev/block/{disk}').split()[0]
    local = subprocess.check_output(['sha256sum', str(partial)], text=True).split()[0]
    assert remote == local == digest.hexdigest(), f'{disk} hash mismatch'
    unmounted()
    partial.rename(out / f'{disk}.img')
    info['sha256'] = local
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{disk}: VERIFIED {local}', flush=True)
(out / 'SHA256SUMS').write_text(''.join(f'{v["sha256"]}  {k}.img\n' for k,v in manifest['disks'].items()))
(out / 'VERIFIED.txt').write_text('All six exact-sized UFS images match independent device and saved-file SHA256 reads.\n')
print(f'Complete verified internal backup: {out}', flush=True)
