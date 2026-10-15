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
        vpn.profile.host = "vpn.company.kz"
        vpn.profile.username = "your.name"
        vpn.profile.rememberPassword = true
        vpn.phase = "Подключено"
        vpn.connected = true
        vpn.details = ConnectionDetails(session: "preview", address: "10.10.0.24/24", interface: "utun", transport: "SSL",
                                        received: 52_432_000, sent: 10_430_000, since: Date().addingTimeInterval(-864))
        try render(ContentView(vpn: vpn), size: NSSize(width: 1040, height: 800), to: output.appendingPathComponent("app.png"))
        try render(MenuBarPanel(vpn: vpn), size: NSSize(width: 360, height: 474), to: output.appendingPathComponent("menu.png"))
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
