import ServiceManagement
import SwiftUI

@main
struct armanVPNApp: App {
    @State private var vpn = VPNController()

    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) {
            do { try PreviewExporter.export(to: CommandLine.arguments[index + 1]); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        #endif
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
            ContentView(vpn: vpn)
                .onDisappear { vpn.saveProfile() }
                .onAppear {
                    if CommandLine.arguments.contains("--enable-service") { vpn.enableService() }
                    if CommandLine.arguments.contains("--connect") { vpn.connect() }
                }
        }
        .defaultSize(width: 1040, height: 800)
        .windowResizability(.contentMinSize)

        MenuBarExtra("armanVPN", systemImage: vpn.connected ? "lock.shield.fill" : "lock.shield") {
            MenuBarPanel(vpn: vpn)
        }
        .menuBarExtraStyle(.window)
    }
}
