// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArmanVPNCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ArmanVPNCore", path: "armanVPN",
                exclude: ["ContentView.swift", "armanVPNApp.swift", "VPNController.swift", "DesktopTools.swift", "ToolsViews.swift", "ArmanBrand.swift", "MenuBarPanel.swift", "PreviewExporter.swift", "Models/ArmanPersonality.swift", "Info.plist", "Assets.xcassets", "Legal", "Services/BackgroundService.swift"],
                sources: ["Models/VPNProfile.swift", "Services/EngineClient.swift", "Services/GatewayClient.swift",
                          "Services/KeychainStore.swift", "Services/TrustStore.swift", "Models/CodexUsage.swift", "Models/MacHealth.swift",
                          "Services/CodexUsageService.swift", "Services/MacHealthService.swift"],
                linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "ArmanVPNCoreTests", dependencies: ["ArmanVPNCore"], path: "Tests")
    ]
)
