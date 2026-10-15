#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
bash "$project_dir/scripts/build-engine.sh"
rustup +1.94.0 target add aarch64-apple-darwin x86_64-apple-darwin
engine_dir="$project_dir/.build/snx-rs"
native_arch="$(uname -m)"
for architecture in arm64 x86_64; do
    if [ "$architecture" = "$native_arch" ]; then
        install -m 755 "$project_dir/.build/engine/armanvpn-engine" "$project_dir/.build/engine/armanvpn-engine-$architecture"
    else
        if [ "$architecture" = arm64 ]; then triple=aarch64-apple-darwin; else triple=x86_64-apple-darwin; fi
        MACOSX_DEPLOYMENT_TARGET=14.0 cargo +1.94.0 build --manifest-path "$engine_dir/Cargo.toml" \
            --locked --release -p snx-rs --features snxcore/vendored-openssl --target "$triple"
        install -m 755 "$engine_dir/target/$triple/release/snx-rs" "$project_dir/.build/engine/armanvpn-engine-$architecture"
    fi
done
lipo -create "$project_dir/.build/engine/armanvpn-engine-arm64" "$project_dir/.build/engine/armanvpn-engine-x86_64" \
    -output "$project_dir/.build/engine/armanvpn-engine-universal"
chmod 755 "$project_dir/.build/engine/armanvpn-engine-universal"
lipo "$project_dir/.build/engine/armanvpn-engine-universal" -verify_arch arm64 x86_64
