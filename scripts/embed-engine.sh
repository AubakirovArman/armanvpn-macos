#!/bin/bash
set -euo pipefail
app_contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
engine_binary="${ARMANVPN_ENGINE_BINARY:-$SRCROOT/.build/engine/armanvpn-engine}"
if [ ! -x "$engine_binary" ]; then
    printf 'warning: VPN engine not built. Run bash scripts/build-engine.sh to enable connections.\n'
    exit 0
fi
mkdir -p "$app_contents/MacOS" "$app_contents/Library/LaunchDaemons"
install -m 755 "$engine_binary" "$app_contents/MacOS/armanvpn-engine"
install -m 644 "$SRCROOT/engine/armanibadboy.armanVPN.engine.plist" "$app_contents/Library/LaunchDaemons/"
mkdir -p "$app_contents/Resources/Engine"
install -m 644 "$SRCROOT/engine/COPYING" "$SRCROOT/engine/armanvpn.patch" "$SRCROOT/engine/UPSTREAM.txt" "$app_contents/Resources/Engine/"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$app_contents/MacOS/armanvpn-engine"
fi
