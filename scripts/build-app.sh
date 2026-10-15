#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$project_dir/armanVPN.xcodeproj" -scheme armanVPN -configuration Debug \
    -derivedDataPath "$project_dir/.build/xcode" build
printf 'App: %s\n' "$project_dir/.build/xcode/Build/Products/Debug/armanVPN.app"
