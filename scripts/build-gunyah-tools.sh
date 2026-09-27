#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${GUNYAH_TOOLS_OUT:-$repo/out/gunyah-tools}
mkdir -p "$out"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
    ${TOOLS_LDFLAGS:-} -o "$out/gunyah-smoke" "$repo/scripts/gunyah-smoke.c"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror ${TOOLS_LDFLAGS:-} \
    -o "$out/waydroid-kernel-smoke" "$repo/scripts/waydroid-kernel-smoke.c"
sha256sum "$out/gunyah-smoke" "$out/waydroid-kernel-smoke"
