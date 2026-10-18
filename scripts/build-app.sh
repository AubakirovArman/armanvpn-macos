#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -x "$project_dir/.build/engine/armanvpn-engine-arm64" ]; then
    bash "$project_dir/scripts/build-engine.sh"
fi
xcodebuild -project "$project_dir/armanVPN.xcodeproj" -scheme armanVPN -configuration Debug \
    -derivedDataPath "$project_dir/.build/xcode" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
printf 'App: %s\n' "$project_dir/.build/xcode/Build/Products/Debug/armanVPN.app"
