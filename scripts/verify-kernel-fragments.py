#!/usr/bin/env python3
"""Verify all explicit requirements, rejecting contradictory fragments too."""
import re
import sys
from pathlib import Path


def parse(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r'(CONFIG_\w+)=(.*)', line)
        disabled = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
        if match:
            result[match[1]] = match[2]
        elif disabled:
            result[disabled[1]] = 'n'
    return result


def verify(config, fragments):
    actual = parse(config)
    wanted = {}
    errors = []
    for fragment in fragments:
        for key, value in parse(fragment).items():
            if key in wanted and wanted[key] != value:
                errors.append(f'{fragment}: conflicting request for {key}')
            wanted[key] = value
            if actual.get(key) != value:
                errors.append(f'{key}: wanted {value}, resolved {actual.get(key, "<absent>")}')
    return errors


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit('usage: verify-kernel-fragments.py CONFIG FRAGMENT...')
    errors = verify(sys.argv[1], sys.argv[2:])
    print('\n'.join(errors) if errors else 'All kernel fragment requirements verified')
    sys.exit(bool(errors))
