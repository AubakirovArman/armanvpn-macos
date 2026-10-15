import Foundation
import ServiceManagement

enum BackgroundService {
    static let identifier = "armanibadboy.armanVPN.engine.plist"
    static var service: SMAppService { .daemon(plistName: identifier) }

    static var label: String {
        switch service.status {
        case .enabled: "Разрешена"
        case .requiresApproval: "Ожидает разрешения в macOS"
        case .notRegistered: "Не установлена"
        case .notFound: FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/armanvpn-engine").path)
            ? "Не зарегистрирована" : "Ядро отсутствует в сборке"
        @unknown default: "Неизвестно"
        }
    }

    static func register() throws {
        guard FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/armanvpn-engine").path) else {
            throw VPNError.message("Сначала соберите VPN-ядро: scripts/build-engine.sh и scripts/build-app.sh.")
        }
        if service.status != .enabled && service.status != .requiresApproval {
            do { try service.register() }
            catch { if service.status != .requiresApproval { throw error } }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func unregister() async throws { try await service.unregister() }
}
