import Darwin
import Foundation
import Security

enum CoolingIPC {
    static let socketPath = "/var/run/armanvpn-cooling.sock"
    static let maximumPacket = 16_384
    static let helperIdentifier = "armanibadboy.armanVPN.cooling-helper"
    static let appIdentifier = "armanibadboy.armanVPN"

    static func exchange(_ request: CoolingRequest) throws -> CoolingStatus {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw VPNError.message("Служба охлаждения ещё не запущена. Разрешите её в macOS.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError.message("Не удалось открыть канал охлаждения.") }
        defer { close(fd) }
        configure(fd, timeout: 10)
        var address = address()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw VPNError.message("Служба охлаждения недоступна.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw VPNError.message("Подлинность службы охлаждения не подтверждена.") }
        try verifyPeer(fd, identifier: helperIdentifier)
        try send(try JSONEncoder().encode(request), to: fd)
        let reply = try JSONDecoder().decode(CoolingReply.self, from: receive(from: fd))
        if let error = reply.error { throw VPNError.message(error) }
        guard let status = reply.status else { throw VPNError.message("Неизвестный ответ службы охлаждения.") }
        return status
    }

    static func configure(_ fd: Int32, timeout: Int) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
    }

    static func address() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func verifyPeer(_ fd: Int32, identifier: String) throws {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout.size(ofValue: token), let team = ownTeamIdentifier() else {
            throw VPNError.message("Не удалось проверить подпись канала охлаждения.")
        }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var peer: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: audit] as CFDictionary
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess, let peer,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else {
            throw VPNError.message("Подпись участника канала охлаждения не совпадает с приложением.")
        }
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any], let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }

    static func send(_ payload: Data, to fd: Int32) throws {
        guard !payload.isEmpty, payload.count <= maximumPacket else { throw VPNError.message("Недопустимый размер команды охлаждения.") }
        var length = UInt32(payload.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }; packet.append(payload)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VPNError.message("Канал охлаждения закрыт.") }
                offset += count
            }
        }
    }

    static func receive(from fd: Int32) throws -> Data {
        let header = try readExactly(fd, count: 4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumPacket else { throw VPNError.message("Недопустимый размер ответа охлаждения.") }
        return try readExactly(fd, count: Int(size))
    }

    private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw VPNError.message("Служба охлаждения не ответила вовремя.") }
                offset += received
            }
        }
        return data
    }
}
