#!/bin/sh
# Private namespaces and disposable network objects; no Android image needed.
set -eu
if [ "${1:-}" != --private ]; then
    exec unshare --mount --net --pid --fork --ipc --uts "$0" --private
fi
mount --make-rprivate /
dir=$(mktemp -d /tmp/x716-binder.XXXXXX)
trap 'umount "$dir" 2>/dev/null || :; rmdir "$dir"' EXIT
mount -t binder binder "$dir"
"${WAYDROID_SMOKE:-$(dirname "$0")/waydroid-kernel-smoke}" "$dir"
unshare --user --map-root-user true
ip link add wdtest0 type veth peer name wdtest1
ip link add wdbr0 type bridge
ip link set wdtest0 master wdbr0
ip link set wdbr0 up
ip link del wdbr0
ip link del wdtest0
nft add table ip wdtest
nft 'add chain ip wdtest postrouting { type nat hook postrouting priority srcnat; }'
nft add rule ip wdtest postrouting masquerade
nft delete table ip wdtest
test -f /sys/fs/cgroup/cgroup.controllers
grep -qw memory /sys/fs/cgroup/cgroup.controllers
printf 'PASS namespaces, veth, bridge, NAT, memory cgroup prerequisites\n'
