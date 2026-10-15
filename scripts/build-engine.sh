#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$project_dir/.build/snx-rs"
engine_revision=86aa48031888050f957af7b6adf2c2e39d4745fd

if [ ! -d "$engine_dir/.git" ]; then
    mkdir -p "$project_dir/.build"
    git clone https://github.com/ancwrd1/snx-rs.git "$engine_dir"
fi
git -C "$engine_dir" checkout --detach "$engine_revision"
git -C "$engine_dir" apply --reverse --check "$project_dir/engine/armanvpn.patch" 2>/dev/null || git -C "$engine_dir" apply "$project_dir/engine/armanvpn.patch"
cargo +1.94.0 build --manifest-path "$engine_dir/Cargo.toml" --locked --release -p snx-rs --features snxcore/vendored-openssl
mkdir -p "$project_dir/.build/engine"
install -m 755 "$engine_dir/target/release/snx-rs" "$project_dir/.build/engine/armanvpn-engine"
printf 'Engine built: %s\n' "$project_dir/.build/engine/armanvpn-engine"
