#!/usr/bin/env python3
"""Bounded file-only I/O comparison; restore the scheduler even after failure.

Run as root on X716B. Does not choose a winner: desktop/energy gates are separate.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    if b'samsung,gts9-5g' not in Path('/sys/firmware/devicetree/base/compatible').read_bytes().split(b'\0'):
        raise RuntimeError('not X716B')
    root = run('findmnt', '-n', '-o', 'SOURCE', '/')
    disk = run('lsblk', '-n', '-o', 'PKNAME', root)
    device = Path('/sys/class/block', disk).resolve(strict=True)
    if not any((p / 'driver').resolve().name == 'ufshcd-qcom' for p in device.parents):
        raise RuntimeError('root is not on Qualcomm UFS')
    sched = device / 'queue/scheduler'
    original = re.search(r'\[(.*?)\]', sched.read_text())[1]
    candidates = ['bfq', 'mq-deadline', 'kyber', 'none']
    if not set(candidates).issubset(set(sched.read_text().replace('[', '').replace(']', '').split())):
        raise RuntimeError('missing scheduler')
    try:
        with tempfile.TemporaryDirectory(prefix='x716-fio-', dir='/var/tmp') as tmp:
            # Seed real extents; a sparse read file would benchmark zero filling.
            run('fio', '--name=seed', f'--filename={tmp}/read', '--size=256M',
                '--rw=write', '--bs=1M', '--direct=1', '--end_fsync=1', '--output-format=json')
            for repetition in range(3):
                for name in candidates[repetition:] + candidates[:repetition]:
                    sched.write_text(name)
                    # Allow previous writes to settle; capture thermal/PSI/power per run.
                    time.sleep(5)
                    before = snapshot()
                    result = run('fio', '--output-format=json', '--ioengine=libaio',
                                 '--direct=1', '--time_based=1', '--runtime=20',
                                 '--name=foreground', f'--filename={tmp}/read', '--size=256M',
                                 '--rw=randread', '--bs=4k', '--iodepth=1',
                                 '--name=background', f'--filename={tmp}/write', '--size=256M',
                                 '--rw=write', '--bs=128k', '--iodepth=16', '--rate=64M')
                    record = {'scheduler': name, 'repetition': repetition + 1,
                              'before': before, 'after': snapshot(), 'fio': json.loads(result)}
                    if any(j['error'] for j in record['fio']['jobs']):
                        raise RuntimeError('fio job failed')
                    (args.output / f'{repetition+1}-{name}.json').write_text(json.dumps(record, indent=2))
    finally:
        sched.write_text(original)


def snapshot():
    result = {'time': time.time(), 'kernel': os.uname().release}
    for pattern in ['/proc/pressure/*', '/sys/class/thermal/thermal_zone*/temp',
                    '/sys/class/backlight/*/brightness', '/sys/class/power_supply/*/uevent']:
        import glob
        for name in glob.glob(pattern):
            try:
                result[name] = Path(name).read_text()
            except OSError:
                pass
    return result


if __name__ == '__main__':
    main()
