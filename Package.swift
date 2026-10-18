// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArmanVPNCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ArmanVPNCore", path: "armanVPN",
                exclude: ["ContentView.swift", "armanVPNApp.swift", "VPNController.swift", "DesktopTools.swift", "ToolsViews.swift", "AudioBalanceController.swift", "CoolingController.swift", "CoolingControlsView.swift", "Services/CoolingService.swift", "ArmanBrand.swift", "MenuBarPanel.swift", "MenuBarStatusImage.swift", "PreviewExporter.swift", "Models/ArmanPersonality.swift", "Info.plist", "Assets.xcassets", "Legal", "Services/BackgroundService.swift"],
                sources: ["Models/VPNProfile.swift", "Services/EngineClient.swift", "Services/GatewayClient.swift",
                          "Services/KeychainStore.swift", "Services/TrustStore.swift", "Models/CodexUsage.swift", "Models/MacHealth.swift",
                          "Services/CodexUsageService.swift", "Services/MacHealthService.swift", "Models/Cooling.swift", "Services/CoolingEngine.swift", "Services/AutomaticCooling.swift", "Services/CoolingIPC.swift", "Services/AudioBalanceLock.swift", "Services/CoreAudioBalanceHardware.swift"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .testTarget(name: "ArmanVPNCoreTests", dependencies: ["ArmanVPNCore"], path: "Tests")
    ]
)
