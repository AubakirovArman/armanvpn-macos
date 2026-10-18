#!/bin/bash
set -euo pipefail
if [ "$#" -eq 0 ]; then
    printf 'Usage: bash scripts/verify-arm64.sh <Mach-O binary> [...]\n' >&2
    exit 1
fi
for binary in "$@"; do
    architecture="$(/usr/bin/lipo -archs "$binary")"
    if [ "$architecture" != arm64 ]; then
        printf 'error: %s must contain only arm64; found: %s\n' "$binary" "$architecture" >&2
        exit 1
    fi
done
