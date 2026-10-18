#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum PreviewExporter {
    static func export(to directory: String) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let vpn = VPNController(startMonitoring: false, loadSavedProfile: false)
        let tools = DesktopTools(startMonitoring: false)
        tools.codex = try JSONDecoder().decode(CodexUsageSnapshot.self, from: Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1792887912},"secondary":null}}"#.utf8))
        tools.codexUpdatedAt = Date()
        tools.health = MacHealthSnapshot(temperatures: [.init(id: "Tp01", celsius: 52), .init(id: "Tf14", celsius: 45)],
                                        fans: [.init(id: 0, rpm: 1850, minimum: 0, maximum: 5700, mode: 0), .init(id: 1, rpm: 1800, minimum: 0, maximum: 5200, mode: 0)],
                                        fanCount: 2, sampledAt: Date())
        tools.temperatureHistory = (0..<60).map { index in
            TemperaturePoint(date: Date().addingTimeInterval(Double(index - 59) * 3), value: 50 + sin(Double(index) / 8) * 5 + Double(index) / 30)
        }
        vpn.profile.host = "vpn.company.kz"
        vpn.profile.username = "your.name"
        vpn.profile.rememberPassword = true
        vpn.phase = "Подключено"
        vpn.connected = true
        vpn.details = ConnectionDetails(session: "preview", address: "10.10.0.24/24", interface: "utun", transport: "SSL",
                                        received: 52_432_000, sent: 10_430_000, since: Date().addingTimeInterval(-864))
        for section in [HubSection.overview, .codex, .mac, .vpn] {
            tools.section = section
            try render(ContentView(vpn: vpn, tools: tools), size: NSSize(width: 1080, height: 860), to: output.appendingPathComponent("\(section.rawValue).png"))
        }
        try render(MenuBarPanel(vpn: vpn, tools: tools), size: NSSize(width: 360, height: 520), to: output.appendingPathComponent("menu.png"))
        try render(SuperAppMenuLabel(connected: true, tools: tools).padding(8).frame(width: 300, height: 32).background(.black).foregroundStyle(.white),
                   size: NSSize(width: 300, height: 32), to: output.appendingPathComponent("menu-label.png"))
        tools.cooling.selectedMode = .automatic
        tools.cooling.startTemperature = 55
        tools.cooling.status = CoolingStatus(policy: .init(mode: .automatic, startTemperature: 55),
            fans: [.init(id: 0, minimum: 1499, maximum: 5348, actual: 2390, target: 2386, forced: true),
                   .init(id: 1, minimum: 1499, maximum: 5776, actual: 2490, target: 2484, forced: true)],
            temperature: 67.8, controlling: true, filteredTemperature: 67.2, controlTemperature: 67,
            automaticReason: "Температура стабильна: удерживаем обороты.")
        try render(CoolingControlsView(cooling: tools.cooling, fans: tools.health!.fans).padding(24)
            .background(ArmanBrand.night).preferredColorScheme(.dark), size: NSSize(width: 820, height: 760),
                   to: output.appendingPathComponent("automatic-cooling.png"))
        for memory in [8, 16, 32, 64] {
            try render(ArmanMemoryCard(personality: ArmanPersonality(memoryGB: memory))
                .padding(20).frame(width: 600, height: 155).background(ArmanBrand.night).preferredColorScheme(.dark),
                       size: NSSize(width: 600, height: 155), to: output.appendingPathComponent("ram-\(memory).png"))
        }
    }

    private static func render<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw VPNError.message("Unable to render preview.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VPNError.message("Unable to encode preview.") }
        try data.write(to: url)
    }
}
#endif
