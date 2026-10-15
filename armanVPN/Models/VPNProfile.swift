import Foundation

struct VPNProfile: Codable, Equatable, Sendable {
    var id = UUID()
    var host = ""
    var port = "443"
    var username = ""
    var loginType = ""
    var rememberPassword = false
    var reconnect = true
    var tunnel = "SSL"
    var transport = "AutoDetect"

    var endpoint: String { port == "443" ? host.lowercased() : "\(host.lowercased()):\(port)" }
    var credentialID: String { "\(endpoint)|\(username)" }

    static func loadSaved(from defaults: UserDefaults = .standard) -> (profile: Self, migratedToSSL: Bool) {
        let saved = defaults.data(forKey: "profile").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        let migrationKey = "profile.sslRecoveryApplied.v1"
        guard !defaults.bool(forKey: migrationKey) else { return (saved, false) }
        guard saved.tunnel == "IPsec" else {
            defaults.set(true, forKey: migrationKey)
            return (saved, false)
        }
        var updated = saved
        updated.tunnel = "SSL"
        updated.transport = "AutoDetect"
        guard let data = try? JSONEncoder().encode(updated) else { return (saved, false) }
        defaults.set(data, forKey: "profile")
        defaults.set(true, forKey: migrationKey)
        return (updated, true)
    }

    func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !host.hasPrefix("-"), !host.hasSuffix("-"),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              let portNumber = UInt16(port), portNumber > 0 else {
            throw VPNError.message("Укажите IP-адрес или имя сервера и порт от 1 до 65535.")
        }
    }
}

enum VPNError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

struct LoginOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct PeerCertificate: Identifiable, Sendable {
    var id: String { fingerprint }
    let endpoint: String
    let subject: String
    let issuer: String
    let fingerprint: String
    let expires: Date?
    let data: Data
    let systemTrusted: Bool
    let validationError: String?
}

struct ConnectionDetails: Sendable {
    var session = ""
    var endpoint = ""
    var username = ""
    var address = ""
    var interface = ""
    var transport = ""
    var tunnelType = ""
    var received: Int64 = 0
    var sent: Int64 = 0
    var since: Date?
}

enum TunnelStatus: Sendable {
    case disconnected
    case connecting
    case connected(ConnectionDetails)
    case challenge(kind: String, prompt: String)
}

struct EngineDiagnostics: Decodable, Sendable {
    let instance: String
    let events: [EngineDiagnosticEvent]
}

struct EngineDiagnosticEvent: Decodable, Sendable {
    let sequence: UInt64
    let at: String
    let code: String
    let value: UInt64?

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: at) ?? ISO8601DateFormatter().date(from: at)
    }

    var message: String {
        switch code {
        case "connected": "VPN-ядро подтвердило подключение."
        case "disconnected": "VPN-ядро завершило туннель."
        case "user_disconnect": "VPN-ядро получило команду отключения от локального клиента."
        case "keepalive_missed": "Пропущен ответ IPsec keepalive; ядро повторяет проверку."
        case "keepalive_timeout": "IPsec отключён после 5 неудачных проверок keepalive."
        case "gateway_deleted_sa": "Шлюз Check Point завершил IPsec-сессию: получена команда IKE DELETE."
        case "ike_expired": "Истёк срок IKE-сессии, выданный шлюзом."
        case "ssl_transport_closed": "Канал SSL-туннеля завершился."
        case "ssl_keepalive_timeout": "SSL-шлюз не ответил на 3 проверки keepalive."
        case "control_error": "Ошибка обработки управляющего сообщения VPN."
        case "ike_exchange_timeout": "Истекло время ожидания ответа на управляющий запрос IKEv2."
        case "ike_control_network_error": "Сетевая ошибка управляющего канала IKEv2."
        case "ike_integrity_failed": "Не прошла проверка целостности управляющего пакета IKEv2."
        case "ike_malformed_packet": "Получен некорректный управляющий пакет IKEv2."
        case "peer_request_failed": "Не удалось обработать управляющий запрос шлюза IKEv2."
        case "office_mode_lease_lifetime": "Шлюз выдал VPN-адрес на \(value ?? 0) секунд."
        case "office_mode_renewal_started": "Начато продление аренды VPN-адреса (Office Mode)."
        case "office_mode_renewal_failed": "Шлюз не подтвердил продление аренды VPN-адреса (Office Mode)."
        case "ipsec_rekey_failed": "Не удалось обновить ключи IPsec-сессии."
        case "tunnel_error": "VPN-ядро завершило работу туннеля с ошибкой."
        default: "Получено диагностическое событие VPN-ядра."
        }
    }

    var isSpecificDisconnectReason: Bool {
        ["keepalive_timeout", "gateway_deleted_sa", "ike_expired", "ssl_keepalive_timeout", "ssl_transport_closed", "ike_exchange_timeout", "ike_control_network_error", "ike_integrity_failed", "ike_malformed_packet", "peer_request_failed", "office_mode_renewal_failed", "ipsec_rekey_failed"].contains(code)
    }
}
