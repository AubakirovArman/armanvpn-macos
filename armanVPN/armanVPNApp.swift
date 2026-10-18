import ServiceManagement
import SwiftUI

@main
struct armanVPNApp: App {
    @State private var vpn = VPNController(startMonitoring: !armanVPNApp.isProbe, loadSavedProfile: !armanVPNApp.isProbe)
    @State private var tools = DesktopTools(startMonitoring: !armanVPNApp.isProbe)
    private static var isProbe: Bool { CommandLine.arguments.contains("--render-previews") || CommandLine.arguments.contains("--tools-check") }

    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) {
            do { try PreviewExporter.export(to: CommandLine.arguments[index + 1]); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        #endif
        if CommandLine.arguments.contains("--tools-check") {
            Task { @MainActor in
                var report: [String: Any] = [:]
                do {
                    let health = try await MacHealthService().sample()
                    report["hardware"] = ["temperatures": health.temperatures.count,
                                          "cpu": health.cpuTemperature.map { $0 as Any } ?? NSNull(),
                                          "gpu": health.gpuTemperature.map { $0 as Any } ?? NSNull(),
                                          "fans": health.fans.map { ["id": $0.id, "rpm": $0.rpm.map { $0 as Any } ?? NSNull(), "mode": $0.mode.map { $0 as Any } ?? NSNull()] }]
                } catch { report["hardware_error"] = error.localizedDescription }
                if let url = CodexUsageService.locateExecutable() {
                    do {
                        let usage = try await Task.detached { try CodexUsageService.fetch(executable: url) }.value
                        report["codex"] = usage.windows.map { ["window_minutes": $0.minutes, "remaining_percent": $0.remaining] }
                    } catch { report["codex_error"] = error.localizedDescription }
                } else { report["codex_error"] = "Codex CLI is not installed" }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                exit(0)
            }
            RunLoop.main.run()
            exit(1)
        }
        if CommandLine.arguments.contains("--service-status") {
            print(BackgroundService.label)
            exit(0)
        }
        if CommandLine.arguments.contains("--register-service") {
            do { try BackgroundService.register(); print(BackgroundService.label); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--unregister-service") {
            if BackgroundService.service.status == .notRegistered {
                print(BackgroundService.label)
                exit(0)
            }
            Task { @MainActor in
                do { try await BackgroundService.unregister(); print(BackgroundService.label); exit(0) }
                catch { print(error.localizedDescription); exit(1) }
            }
            RunLoop.main.run()
            exit(1)
        }
    }

    var body: some Scene {
        Window("armanVPN", id: "main") {
            ContentView(vpn: vpn, tools: tools)
                .onDisappear { vpn.saveProfile() }
                .onAppear {
                    if CommandLine.arguments.contains("--enable-service") { vpn.enableService() }
                    if CommandLine.arguments.contains("--connect") { vpn.connect() }
                }
        }
        .defaultSize(width: 1080, height: 860)
        .windowResizability(.contentMinSize)

        MenuBarExtra { MenuBarPanel(vpn: vpn, tools: tools) }
            label: { SuperAppMenuLabel(connected: vpn.connected, tools: tools) }
        .menuBarExtraStyle(.window)
    }
}
