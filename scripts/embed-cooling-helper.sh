#!/bin/bash
set -euo pipefail
app_contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$DERIVED_FILE_DIR/cooling" "$app_contents/MacOS" "$app_contents/Library/LaunchDaemons"
sources=("$SRCROOT/cooling/main.swift" "$SRCROOT/cooling/SMCCoolingHardware.swift"
    "$SRCROOT/armanVPN/Models/VPNProfile.swift" "$SRCROOT/armanVPN/Models/MacHealth.swift"
    "$SRCROOT/armanVPN/Models/Cooling.swift" "$SRCROOT/armanVPN/Services/MacHealthService.swift"
    "$SRCROOT/armanVPN/Services/CoolingIPC.swift" "$SRCROOT/armanVPN/Services/CoolingEngine.swift")
outputs=()
for architecture in $ARCHS; do
    output="$DERIVED_FILE_DIR/cooling/helper-$architecture"
    xcrun swiftc -O -swift-version 5 -D COOLING_HELPER -sdk "$sdk_path" \
        -target "$architecture-apple-macos14.0" -framework IOKit -framework Security "${sources[@]}" -o "$output"
    outputs+=("$output")
done
xcrun lipo -create "${outputs[@]}" -output "$app_contents/MacOS/armanvpn-cooling-helper"
chmod 755 "$app_contents/MacOS/armanvpn-cooling-helper"
install -m 644 "$SRCROOT/cooling/armanibadboy.armanVPN.cooling.plist" "$app_contents/Library/LaunchDaemons/"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp=none --identifier armanibadboy.armanVPN.cooling-helper \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$app_contents/MacOS/armanvpn-cooling-helper"
fi
