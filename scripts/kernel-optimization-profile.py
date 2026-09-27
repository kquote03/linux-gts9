#!/usr/bin/env python3
"""Emit a fully verifiable comparison profile with a unique module release."""
from pathlib import Path
import sys

profile, source, output = sys.argv[1:]
if profile not in ('baseline', 'hz1000', 'slice400', 'hz1000-slice400'):
    sys.exit('unknown KERNEL_PROFILE')
s = Path(source).read_text()
s = s.replace('CONFIG_LOCALVERSION="-x716-opt"', f'CONFIG_LOCALVERSION="-x716-opt-{profile}"')
if 'hz1000' in profile:
    s = s.replace('CONFIG_HZ_250=y', 'CONFIG_HZ_250=n').replace('CONFIG_HZ_1000=n', 'CONFIG_HZ_1000=y')
if 'slice400' in profile:
    s = s.replace('CONFIG_X716_SCHED_BASE_SLICE_NS=700000', 'CONFIG_X716_SCHED_BASE_SLICE_NS=400000')
Path(output).write_text(s)
