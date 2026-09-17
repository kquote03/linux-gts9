#!/usr/bin/env python3
"""Sample the desktop camera stack on the tablet; fail on restart or growing RSS.

Run as the desktop user after enabling the candidate plugin, with relays stopped
for the idle test. This observes processes; it does not start cameras/services.
Use --seconds 7200 while exercising streaming, and retain the JSON report.
"""
import argparse
import json
from pathlib import Path
import statistics
import time


def processes():
    result = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            name = (entry / 'comm').read_text().strip()
            if name not in ('wireplumber', 'pipewire', 'v4l2-relayd'):
                continue
            status = (entry / 'status').read_text().splitlines()
            rss = next(int(line.split()[1]) for line in status if line.startswith('VmRSS:'))
            stat = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            result[entry.name] = dict(name=name, start=stat[19], rss_kib=rss,
                                     fds=len(list((entry / 'fd').iterdir())))
            try:
                rollup = (entry / 'smaps_rollup').read_text().splitlines()
                result[entry.name]['pss_kib'] = next(int(line.split()[1]) for line in rollup if line.startswith('Pss:'))
            except (OSError, StopIteration, ValueError):
                pass
        except (OSError, StopIteration, ValueError):
            continue
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=1800)
    parser.add_argument('--interval', type=int, default=10)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.seconds < 60 or args.interval < 1 or args.interval > args.seconds // 6:
        parser.error('use at least 60 seconds and at least six sample intervals')
    samples, errors = [], []
    initial = processes()
    required = {pid: p for pid, p in initial.items() if p['name'] in ('wireplumber', 'pipewire')}
    if {p['name'] for p in required.values()} != {'wireplumber', 'pipewire'}:
        parser.error('running WirePlumber and PipeWire must both be visible')
    started = time.monotonic()
    while True:
        elapsed = time.monotonic() - started
        current = processes()
        samples.append(dict(seconds=round(elapsed, 2), processes=current))
        args.output.with_suffix('.partial.json').write_text(json.dumps(
            dict(completed=False, requested_seconds=args.seconds, samples=samples), indent=2) + '\n')
        for pid, original in required.items():
            if pid not in current or current[pid]['start'] != original['start']:
                errors.append(f"{original['name']} PID {pid} exited or restarted")
        if errors or elapsed >= args.seconds:
            break
        time.sleep(min(args.interval, args.seconds - elapsed))
    # Compare settled thirds, allowing modest allocator/cache variation rather
    # than treating initial startup allocations as a leak. FD counts should
    # also settle; retain every sample so a human can inspect a slow trend.
    if not errors:
        middle = [s for s in samples if args.seconds / 3 <= s['seconds'] < 2 * args.seconds / 3]
        final = [s for s in samples if s['seconds'] >= 2 * args.seconds / 3]
        for pid, original in required.items():
            for field, allowance in (('rss_kib', 16384), ('fds', 8)):
                before = statistics.median(s['processes'][pid][field] for s in middle)
                after = statistics.median(s['processes'][pid][field] for s in final)
                if after - before > allowance:
                    errors.append(f"{original['name']} {field} grew from {before} to {after}")
    args.output.write_text(json.dumps(dict(completed=not errors and elapsed >= args.seconds,
                                         duration=args.seconds, errors=errors, samples=samples), indent=2) + '\n')
    print(f"{'FAIL' if errors else 'PASS'}: {args.output}")
    for error in errors:
        print(error)
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
