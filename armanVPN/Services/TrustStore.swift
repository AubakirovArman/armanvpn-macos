import CryptoKit
import Foundation

enum TrustStore {
    static func temporary(_ certificate: PeerCertificate) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("armanVPN-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("peer.der")
        try certificate.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func certificateURL(endpoint: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("armanVPN/Certificates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("peer-\(key).der")
    }

    static func approved(_ certificate: PeerCertificate) throws -> Bool {
        let path = try certificateURL(endpoint: certificate.endpoint)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        return try Data(contentsOf: path) == certificate.data
    }

    static func save(_ certificate: PeerCertificate) throws {
        guard let expiry = certificate.expires, expiry > Date() else {
            throw VPNError.message("Сертификат истёк или срок действия неизвестен. Обратитесь к администратору VPN.")
        }
        let url = try certificateURL(endpoint: certificate.endpoint)
        try certificate.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
