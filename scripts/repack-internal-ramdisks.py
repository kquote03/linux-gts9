#!/usr/bin/env python3
"""Repack only init_boot/vendor_boot, retaining deployed image metadata."""
import gzip
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys

repo = Path(__file__).resolve().parent.parent
source, stage = map(Path, sys.argv[1:])
stage = stage.resolve()
android = repo / 'third_party/android-tools'
unpack = android / 'mkbootimg/unpack_bootimg.py'
mkboot = android / 'mkbootimg/mkbootimg.py'
avb = android / 'avb/avbtool.py'
ramdisk = stage / 'internal-ramdisk.lz4'
subprocess.run(['lz4', '-l', '-12', '-', str(ramdisk)],
               input=gzip.decompress((stage / 'real-root-initramfs.cpio.gz').read_bytes()), check=True)
for name, size in [('init_boot', 8388608), ('vendor_boot', 100663296)]:
    extracted = stage / f'original-{name}'
    args = shlex.split(subprocess.check_output(
        [sys.executable, str(unpack), '--boot_img', str(source / f'{name}.img'),
         '--out', str(extracted), '--format=mkbootimg'], text=True))
    old_args = list(args)
    options = [i for i, a in enumerate(args) if a in ('--ramdisk', '--vendor_ramdisk', '--vendor_ramdisk_fragment')]
    assert len(options) == 1, 'Unexpected multi-fragment ramdisk; refuse blind replacement'
    args[options[0]+1] = str(ramdisk)
    if '--vendor_cmdline' in args:
        i = args.index('--vendor_cmdline') + 1
        words = args[i].split()
        words = [w for w in words if not w.startswith(('gts9.debugnet=', 'root='))]
        words.append('root=LABEL=X716B_INTERNAL')
        args[i] = ' '.join(words)
    output = stage / f'{name}.img'
    flag = '--vendor_boot' if name == 'vendor_boot' else '--output'
    subprocess.run([sys.executable, str(mkboot), *args, flag, str(output)], check=True)
    subprocess.run([sys.executable, str(avb), 'add_hash_footer', '--image', str(output),
                    '--partition_name', name, '--partition_size', str(size), '--algorithm', 'NONE'], check=True)
    checkdir = stage / f'verified-{name}'
    subprocess.run([sys.executable, str(unpack), '--boot_img', str(output), '--out', str(checkdir)], check=True)
    if name == 'vendor_boot':
        assert (extracted / 'dtb').read_bytes() == (checkdir / 'dtb').read_bytes()
    assert output.stat().st_size == size
    (stage / f'{name}-repack.json').write_text(json.dumps({'original':old_args, 'replacement':args}, indent=2)+'\n')
    print(name, hashlib.sha256(output.read_bytes()).hexdigest())
