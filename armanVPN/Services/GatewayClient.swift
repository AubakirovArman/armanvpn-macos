import CryptoKit
import Foundation
import Security

enum GatewayClient {
    static func inspect(_ profile: VPNProfile) async throws -> PeerCertificate {
        try profile.validate()
        let delegate = CertificateDelegate(endpoint: profile.endpoint, approved: nil)
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: url(profile, path: "/")) }
        catch {
            if let certificate = delegate.certificate { return certificate }
            throw VPNError.message("Не удалось получить сертификат сервера: \(error.localizedDescription)")
        }
        guard let certificate = delegate.certificate else { throw VPNError.message("Сервер не предоставил сертификат.") }
        return certificate
    }

    static func loginOptions(_ profile: VPNProfile, approved: Data) async throws -> [LoginOption] {
        let delegate = CertificateDelegate(endpoint: profile.endpoint, approved: approved)
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url(profile, path: "/clients/"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        (CCCclientRequest
        \t:RequestData (
        \t\t:client_info (
        \t\t\t:client_support_saml (true)
        \t\t\t:client_type (TRAC)
        \t\t\t:client_version (1)))
        \t:RequestHeader (
        \t\t:id (1)
        \t\t:type (ClientHello)))
        """.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000,
              let text = String(data: data, encoding: .utf8) else { throw VPNError.message("Шлюз не вернул параметры Check Point.") }
        let options = try SExpression.parse(text).loginOptions
        guard !options.isEmpty else { throw VPNError.message("Шлюз не предоставил способы входа. Проверьте адрес VPN.") }
        return options
    }

    private static func url(_ profile: VPNProfile, path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = profile.host
        parts.port = Int(profile.port)
        parts.path = path
        return parts.url!
    }

    private static func makeSession(delegate: CertificateDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.tlsMaximumSupportedProtocolVersion = .TLSv12
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

private final class CertificateDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: PeerCertificate?
    private let endpoint: String
    private let approved: Data?
    var certificate: PeerCertificate? { lock.withLock { captured } }

    init(endpoint: String, approved: Data?) {
        self.endpoint = endpoint
        self.approved = approved
    }

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(leaf) as Data
        SecTrustSetNetworkFetchAllowed(trust, false)
        var evaluationError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &evaluationError)
        let fields = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any]
        let expiryField = fields?[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any]
        let expiry = (expiryField?[kSecPropertyKeyValue as String] as? NSNumber).map {
            Date(timeIntervalSinceReferenceDate: $0.doubleValue)
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
        let certificate = PeerCertificate(
            endpoint: endpoint,
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "Без имени",
            issuer: chain.dropFirst().first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Неизвестен",
            fingerprint: fingerprint, expires: expiry, data: data, systemTrusted: trusted,
            validationError: evaluationError.map { CFErrorCopyDescription($0) as String }
        )
        lock.withLock { captured = certificate }
        guard let approved, approved == data, let expiry, expiry > Date() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Trust only the exact leaf explicitly accepted for this endpoint. No system trust is changed.
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

indirect enum SExpression {
    case atom(String)
    case list([SExpression])

    var loginOptions: [LoginOption] {
        guard case .list(let values) = self else { return [] }
        if let id = field("id"), let title = field("display_name") { return [LoginOption(id: id, title: title)] }
        return values.flatMap(\.loginOptions)
    }

    private func field(_ name: String) -> String? {
        guard case .list(let values) = self else { return nil }
        for index in values.indices.dropLast() {
            if case .atom(":" + name) = values[index], case .list(let content) = values[index + 1],
               content.count == 1, case .atom(let value) = content[0] { return value }
        }
        return nil
    }

    static func parse(_ text: String) throws -> SExpression {
        let chars = Array(text)
        var index = 0
        func skipSpace() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
        func read(depth: Int) throws -> SExpression {
            guard depth < 64 else { throw VPNError.message("Слишком вложенный ответ шлюза.") }
            skipSpace()
            guard index < chars.count else { throw VPNError.message("Неполный ответ шлюза.") }
            if chars[index] == "(" {
                index += 1
                var values: [SExpression] = []
                while true {
                    skipSpace()
                    guard index < chars.count else { throw VPNError.message("Неполный ответ шлюза.") }
                    if chars[index] == ")" { index += 1; return .list(values) }
                    values.append(try read(depth: depth + 1))
                }
            }
            var value = ""
            if chars[index] == "\"" {
                index += 1
                var closed = false
                while index < chars.count {
                    let character = chars[index]
                    index += 1
                    if character == "\"" { closed = true; break }
                    if character == "\\", index < chars.count {
                        value.append(chars[index]); index += 1
                    } else { value.append(character) }
                }
                guard closed else { throw VPNError.message("Неполная строка в ответе шлюза.") }
            } else {
                while index < chars.count && !chars[index].isWhitespace && chars[index] != "(" && chars[index] != ")" {
                    value.append(chars[index]); index += 1
                }
                guard !value.isEmpty else { throw VPNError.message("Некорректный ответ шлюза.") }
            }
            return .atom(value)
        }
        let result = try read(depth: 0)
        skipSpace()
        guard index == chars.count else { throw VPNError.message("Лишние данные в ответе шлюза.") }
        return result
    }
}
