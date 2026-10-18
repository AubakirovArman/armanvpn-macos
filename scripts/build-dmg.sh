#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
engine_binary="$project_dir/.build/engine/armanvpn-engine-arm64"
if [ ! -x "$engine_binary" ]; then bash "$project_dir/scripts/build-engine.sh"; fi
bash "$project_dir/scripts/verify-arm64.sh" "$engine_binary"
xcodebuild -project "$project_dir/armanVPN.xcodeproj" -scheme armanVPN -configuration Release \
    -derivedDataPath "$project_dir/.build/distribution" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    ENABLE_DEBUG_DYLIB=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARMANVPN_ENGINE_BINARY="$engine_binary" build
app="$project_dir/.build/distribution/Build/Products/Release/armanVPN.app"
signing_identity="$(codesign --display --verbose=4 "$app" 2>&1 | awk '/^Authority=/ && !found {sub(/^Authority=/, ""); print; found=1}')"
if [ -z "$signing_identity" ]; then
    printf 'No signing identity was found in the built application.\n' >&2
    exit 1
fi
# The embed phase can update engine resources during an incremental build.
codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
bash "$project_dir/scripts/verify-arm64.sh" "$app/Contents/MacOS/armanVPN" \
    "$app/Contents/MacOS/armanvpn-engine" "$app/Contents/MacOS/armanvpn-cooling-helper"
if [ ! -x "$project_dir/.build/dmg-venv/bin/dmgbuild" ]; then
    python3 -m venv "$project_dir/.build/dmg-venv"
    "$project_dir/.build/dmg-venv/bin/python" -m pip install "dmgbuild==1.6.7"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p "$project_dir/dist"
image_path="$project_dir/dist/armanVPN-Friends-$version-apple-silicon.dmg"
"$project_dir/.build/dmg-venv/bin/dmgbuild" -D "project=$project_dir" -s "$project_dir/packaging/dmg-settings.py" "armanVPN — для своих" "$image_path"
cd "$project_dir/dist"
shasum -a 256 "$(basename "$image_path")" > "$image_path.sha256"
hdiutil verify "$image_path"
printf 'DMG: %s\n' "$image_path"
