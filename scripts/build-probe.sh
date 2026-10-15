#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 6 \
    armanVPN/Models/VPNProfile.swift armanVPN/Services/EngineClient.swift \
    armanVPN/Services/GatewayClient.swift armanVPN/Services/KeychainStore.swift \
    armanVPN/Services/TrustStore.swift tools/ConnectionProbe.swift \
    -o .build/connection-probe
