import Foundation
import ServiceManagement

enum CoolingService {
    static var service: SMAppService { .daemon(plistName: "armanibadboy.armanVPN.cooling.plist") }
    static var label: String {
        switch service.status {
        case .enabled: "Разрешена"
        case .requiresApproval: "Ожидает разрешения в macOS"
        case .notRegistered, .notFound: "Не установлена"
        @unknown default: "Статус неизвестен"
        }
    }
    static func register() throws {
        guard FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/armanvpn-cooling-helper").path) else {
            throw VPNError.message("В этой сборке отсутствует служба охлаждения.")
        }
        if service.status != .enabled && service.status != .requiresApproval {
            do { try service.register() }
            catch { if service.status != .requiresApproval { throw error } }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
