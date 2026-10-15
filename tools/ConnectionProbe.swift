import Darwin
import Foundation

// Test credentials are read from stdin, never command arguments or files.
@main
struct ConnectionProbe {
    static func main() async {
        var ownsConnection = false
        do {
            guard let line = readLine(), let input = line.data(using: .utf8),
                  let config = try JSONSerialization.jsonObject(with: input) as? [String: String],
                  let host = config["host"], let expectedFingerprint = config["fingerprint"] else {
                throw VPNError.message("Expected connection configuration on stdin.")
            }
            var profile = VPNProfile()
            profile.host = host
            profile.port = config["port"] ?? "443"
            profile.username = config["username"] ?? ""
            profile.tunnel = config["tunnel"] ?? profile.tunnel
            profile.transport = config["transport"] ?? "AutoDetect"
            profile.rememberPassword = true
            let certificate = try await GatewayClient.inspect(profile)
            guard certificate.fingerprint == expectedFingerprint else { throw VPNError.message("Certificate fingerprint changed. Approval required.") }
            try TrustStore.save(certificate)
            let options = try await GatewayClient.loginOptions(profile, approved: certificate.data)
            print("Certificate matched. Login options: \(options.map { "\($0.id): \($0.title)" }.joined(separator: "; "))")
            fflush(stdout)
            guard let selected = options.first(where: { $0.id == config["loginType"] }) ?? options.first else { throw VPNError.message("No login options.") }
            profile.loginType = selected.id
            if config["action"] == "inspect" { return }
            guard let password = try config["password"] ?? KeychainStore.password(for: profile.credentialID), !password.isEmpty else { throw VPNError.message("Password missing.") }
            let parameters = EngineClient.parameters(profile: profile, password: password,
                                                      certificate: try TrustStore.certificateURL(endpoint: profile.endpoint))
            guard case .disconnected = try await EngineClient.status() else {
                throw VPNError.message("A tunnel is already active. Disconnect it before starting a new test.")
            }
            ownsConnection = true
            try EngineClient.checkResponse(await EngineClient.request(["Connect": parameters], timeout: 120))
            var passwordSent = false
            var usernameSent = false
            var first: ConnectionDetails?
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                switch try await EngineClient.status() {
                case .connected(let details): first = details
                case .disconnected: throw VPNError.message("Gateway disconnected during authentication.")
                case .connecting: break
                case .challenge(let kind, _):
                    let answer: String
                    if kind == "UserNameInput", !usernameSent { answer = profile.username; usernameSent = true }
                    else if kind == "PasswordInput", !passwordSent { answer = password; passwordSent = true }
                    else { throw VPNError.message("Additional authentication required: \(kind). Use the app.") }
                    try EngineClient.checkResponse(await EngineClient.request(["ChallengeCode": [answer, parameters]], timeout: 120))
                }
                if first != nil { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let first else { throw VPNError.message("Connection timed out.") }
            guard !first.session.isEmpty else { throw VPNError.message("Missing session timestamp.") }
            print("CONNECTED interface=\(first.interface) address=\(first.address) transport=\(first.transport) since=\(first.session)")
            fflush(stdout)
            if config["save"] == "true" {
                try KeychainStore.save(password, for: profile.credentialID)
                let defaults = UserDefaults(suiteName: "armanibadboy.armanVPN")!
                defaults.set(try JSONEncoder().encode(profile), forKey: "profile")
                defaults.synchronize()
            }
            let started = Date()
            var checks = 0
            var healthChecks = 0
            let seconds = Int(config["seconds"] ?? "600") ?? 600
            while true {
                guard case .connected(let current) = try await EngineClient.status(),
                      current.session == first.session, current.interface == first.interface else {
                    throw VPNError.message("FAIL: tunnel dropped or reconnected.")
                }
                checks += 1
                if let healthHost = config["healthHost"] {
                    guard await tcpCheck(healthHost, port: 443) else { throw VPNError.message("FAIL: internal service is unreachable.") }
                    healthChecks += 1
                }
                let elapsed = Int(Date().timeIntervalSince(started))
                print("elapsed=\(elapsed)s checks=\(checks) health=\(healthChecks) rx=\(current.received) tx=\(current.sent) session=unchanged")
                fflush(stdout)
                if elapsed >= seconds { break }
                try await Task.sleep(for: .seconds(10))
            }
            print("PASS: \(seconds) seconds, no disconnects or reconnects, \(healthChecks) successful internal TCP checks.")
            fflush(stdout)
        } catch {
            // Avoid echoing arbitrary protocol errors, which may contain authentication data.
            let message = error is VPNError ? error.localizedDescription : "\(type(of: error)): operation failed"
            print("ERROR: \(message)")
            fflush(stdout)
            if ownsConnection { _ = try? await EngineClient.request("Disconnect") }
            exit(1)
        }
    }

    static func tcpCheck(_ host: String, port: UInt16) async -> Bool {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
            let flags = fcntl(fd, F_GETFL)
            guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result == 0 { return true }
            guard errno == EINPROGRESS else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&descriptor, 1, 3000) > 0 else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
        }.value
    }
}
