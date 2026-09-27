#!/bin/sh
# Read-only; run on the tablet and save stdout on the host.
set -eu
printf 'UTC: '; date -u
uname -a
cat /proc/cmdline
findmnt /
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL
cat /proc/meminfo /proc/swaps
for f in /proc/pressure/* /proc/sys/vm/swappiness /sys/kernel/mm/lru_gen/enabled \
 /sys/block/*/queue/scheduler /sys/block/*/queue/iosched/low_latency \
 /sys/block/zram*/comp_algorithm /sys/block/zram*/mm_stat \
 /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
 /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq \
 /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp \
 /sys/class/backlight/*/brightness /sys/class/power_supply/*/uevent; do
 [ -r "$f" ] || continue
 printf '\n%s\n' "$f"; cat "$f"
done
for disk in /sys/block/*; do
 printf '\n%s -> %s\n' "$disk" "$(readlink -f "$disk")"
done
powerprofilesctl get 2>/dev/null || true
cat /sys/firmware/devicetree/base/model
printf '\n'
