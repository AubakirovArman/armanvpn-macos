import Darwin
import Foundation

enum EngineClient {
    static let socketPath = "/var/run/armanvpn.sock"

    static func request(_ object: Any, timeout: Int = 5) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
        return try await Task.detached { try exchange(payload, timeout: timeout) }.value
    }

    static func status() async throws -> TunnelStatus {
        try decodeStatus(await request("GetStatus"))
    }

    static func diagnostics() async throws -> EngineDiagnostics {
        try decodeDiagnostics(await request("GetDiagnostics"))
    }

    static func decodeDiagnostics(_ data: Data) throws -> EngineDiagnostics {
        try checkResponse(data)
        struct Response: Decodable { let Diagnostics: EngineDiagnostics }
        return try JSONDecoder().decode(Response.self, from: data).Diagnostics
    }

    static func checkResponse(_ data: Data) throws {
        if let response = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any],
           let error = response["Error"] as? String { throw VPNError.message(error) }
    }

    static func decodeStatus(_ data: Data) throws -> TunnelStatus {
        try checkResponse(data)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = response["ConnectionStatus"] else { throw VPNError.message("Непонятный ответ VPN-службы.") }
        if let state = state as? String {
            switch state {
            case "Disconnected": return .disconnected
            case "Connecting": return .connecting
            default: throw VPNError.message("Неизвестное состояние VPN-службы.")
            }
        }
        if let state = state as? [String: Any] {
            if let info = state["Connected"] as? [String: Any] {
                let live = info["live"] as? [String: Any] ?? [:]
                let timestamp = info["since"] as? String ?? ""
                let precise = ISO8601DateFormatter()
                precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return .connected(ConnectionDetails(
                    session: timestamp,
                    endpoint: info["server_name"] as? String ?? "",
                    username: info["username"] as? String ?? "",
                    address: info["ip_address"] as? String ?? "",
                    interface: info["interface_name"] as? String ?? "",
                    transport: info["transport_type"] as? String ?? "",
                    tunnelType: info["tunnel_type"] as? String ?? "",
                    received: (live["bytes_rx"] as? NSNumber)?.int64Value ?? 0,
                    sent: (live["bytes_tx"] as? NSNumber)?.int64Value ?? 0,
                    since: precise.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
                ))
            }
            if let challenge = state["Mfa"] as? [String: Any],
               let kind = challenge["mfa_type"] as? String, let prompt = challenge["prompt"] as? String {
                return .challenge(kind: kind, prompt: prompt)
            }
        }
        throw VPNError.message("Неизвестное состояние VPN-службы.")
    }

    // This dictionary is the wire schema of the pinned snx-rs revision, not a saved configuration.
    static func parameters(profile: VPNProfile, password: String, certificate: URL) -> [String: Any] {
        let none = NSNull()
        return [
            "profile_name": "armanVPN", "profile_id": profile.id.uuidString.lowercased(),
            "server_name": profile.endpoint, "user_name": profile.username, "password": password,
            "password_factor": 1, "log_level": "off", "search_domains": [], "ignore_search_domains": [],
            "dns_servers": [], "ignore_dns_servers": [], "default_route": false, "no_routing": false,
            "add_routes": [], "ignore_routes": [], "no_dns": false, "no_split_dns": false,
            "ignore_server_cert": false, "tunnel_type": profile.tunnel, "ca_cert": [certificate.path],
            "login_type": profile.loginType, "cert_type": "None", "cert_path": none,
            "cert_password": none, "cert_id": none, "if_name": none, "keychain": false,
            "ike_version": "AutoDetect", "ike_lifetime": ["secs": 28800, "nanos": 0],
            "ike_persist": false, "client_mode": "secure_connect", "no_keepalive": false,
            "icon_theme": "AutoDetect", "color_theme": "AutoDetect", "set_routing_domains": false,
            "port_knock": false, "locale": "ru-RU", "auto_connect": false, "auto_disconnect": false,
            "ip_lease_time": none, "disable_ipv6": false, "mtu": 1350,
            "transport_type": profile.transport, "allow_forwarding": false, "tls_version_max": "Tls12",
            "client_logging_data": none, "use_internal_gateway_ip": false, "notification_level": "Off"
        ]
    }

    nonisolated private static func exchange(_ payload: Data, timeout: Int) throws -> Data {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw VPNError.message("VPN-служба ещё не запущена. Разрешите её в настройках приложения.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError.message("Не удалось открыть канал VPN-службы.") }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw VPNError.message("VPN-служба недоступна. Проверьте разрешение фоновой службы.") }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw VPNError.message("Подлинность VPN-службы не подтверждена.") }
        var length = UInt32(payload.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(payload)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VPNError.message("Не удалось отправить команду VPN-службе.") }
                offset += count
            }
        }
        let header = try readExactly(fd, count: 4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= 1_000_000 else { throw VPNError.message("Недопустимый размер ответа VPN-службы.") }
        return try readExactly(fd, count: Int(size))
    }

    nonisolated private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw VPNError.message("VPN-служба не ответила вовремя.") }
                offset += received
            }
        }
        return data
    }
}
