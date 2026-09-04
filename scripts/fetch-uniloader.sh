#!/usr/bin/env bash
# Fetch the pinned uniLoader checkout this port builds against.
#
# uniLoader (github.com/ivoszbg/uniLoader, GPLv2) is an active upstream
# project, so it's pinned and fetched here rather than vendored into git
# history — same pattern as scripts/fetch-mainline.sh for the kernel.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${UNILOADER_SRC:-$repo_root/uniloader/upstream}
commit=${UNILOADER_COMMIT:-2418e06635e931e31c74833b8809415fa9695b79}
upstream=https://github.com/ivoszbg/uniLoader

mkdir -p "$(dirname "$target")"

if [ ! -d "$target/.git" ]; then
	echo "cloning uniLoader from upstream"
	git clone "$upstream" "$target"
else
	echo "already present: $target"
	git -C "$target" fetch origin
fi

git -C "$target" checkout --detach "$commit"

head=$(git -C "$target" rev-parse HEAD)
if [ "$head" != "$commit" ]; then
	echo "checkout is at $head, expected the pinned $commit" >&2
	exit 1
fi

echo "pinned commit verified: $head"
git -C "$target" log -1 --format='%cI %s'
