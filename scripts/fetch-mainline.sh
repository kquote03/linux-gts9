#!/usr/bin/env bash
# Fetch the pinned mainline Linux checkout this port builds against.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${LINUX_SRC:-$repo_root/kernel/linux}
tag=${LINUX_TAG:-v7.2}
commit=${LINUX_COMMIT:-8d3ae59288f1e7d58d76558a6ee96d533bc5019f}
upstream=https://github.com/torvalds/linux.git

mkdir -p "$(dirname "$target")"

if [ ! -d "$target/.git" ]; then
	echo "cloning $tag from upstream"
	git clone --depth 1 --branch "$tag" "$upstream" "$target"
else
	echo "already present: $target"
fi

head=$(git -C "$target" rev-parse HEAD)
if [ "$head" != "$commit" ]; then
	echo "checkout is at $head, expected the pinned $commit" >&2
	exit 1
fi

echo "pinned commit verified: $head"
git -C "$target" describe --always --tags

# Sanity check: the SoC/PMIC devicetree includes this board file needs must
# exist at this pin (verified for v7.2 before choosing it, but re-check here
# in case LINUX_TAG/LINUX_COMMIT are overridden).
for f in sm8550.dtsi pm8550.dtsi pm8550vs.dtsi pmk8550.dtsi; do
	path="$target/arch/arm64/boot/dts/qcom/$f"
	if [ ! -f "$path" ]; then
		echo "expected devicetree include missing: $path" >&2
		exit 1
	fi
done
echo "sm8550/pm8550 devicetree includes present"
