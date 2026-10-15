import Foundation
import Testing
@testable import ArmanVPNCore

@Test func rejectsInvalidEndpoints() throws {
    for host in ["", "https://vpn.example.com", "vpn.example.com/clients", "vpn.example.com:443", "vpn.example.com\n", "../peer"] {
        var profile = VPNProfile()
        profile.host = host
        #expect(throws: VPNError.self) { try profile.validate() }
    }
    for port in ["0", "65536", "-1", "443\n", "abc"] {
        var profile = VPNProfile()
        profile.host = "vpn.example.com"
        profile.port = port
        #expect(throws: VPNError.self) { try profile.validate() }
    }
    var profile = VPNProfile()
    profile.host = "vpn.example.com"
    try profile.validate()
}

@Test func profileDoesNotPersistPassword() throws {
    var profile = VPNProfile()
    profile.host = "vpn.example.com"
    profile.username = "test-user"
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    #expect(object["password"] == nil)
    #expect(object["username"] as? String == "test-user")
    let params = EngineClient.parameters(profile: profile, password: "test-only-secret", certificate: URL(fileURLWithPath: "/tmp/peer.der"))
    #expect(params["ignore_server_cert"] as? Bool == false)
    #expect(params["ike_persist"] as? Bool == false)
    #expect(params["default_route"] as? Bool == false)
}

@Test func migratesLegacyIPsecWithoutLosingAccountSettings() throws {
    let suite = "armanVPN.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var legacy = VPNProfile()
    legacy.host = "vpn.example.com"
    legacy.port = "4443"
    legacy.username = "test-user"
    legacy.loginType = "vpn_otp"
    legacy.rememberPassword = true
    legacy.reconnect = false
    legacy.tunnel = "IPsec"
    legacy.transport = "Udp"
    defaults.set(try JSONEncoder().encode(legacy), forKey: "profile")

    let loaded = VPNProfile.loadSaved(from: defaults)
    var expected = legacy
    expected.tunnel = "SSL"
    expected.transport = "AutoDetect"
    #expect(loaded.migratedToSSL)
    #expect(loaded.profile == expected)
    #expect(loaded.profile.credentialID == legacy.credentialID)
    let stored = try #require(defaults.data(forKey: "profile"))
    #expect(try JSONDecoder().decode(VPNProfile.self, from: stored) == expected)
    #expect(!VPNProfile.loadSaved(from: defaults).migratedToSSL)

    let parameters = EngineClient.parameters(profile: loaded.profile, password: "test-only-secret", certificate: URL(fileURLWithPath: "/tmp/peer.der"))
    #expect(parameters["tunnel_type"] as? String == "SSL")
}

@Test func preservesManualIPsecChoiceAfterMigration() throws {
    let suite = "armanVPN.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var legacy = VPNProfile()
    legacy.tunnel = "IPsec"
    defaults.set(try JSONEncoder().encode(legacy), forKey: "profile")
    #expect(VPNProfile.loadSaved(from: defaults).migratedToSSL)

    var manual = legacy
    manual.transport = "Tcpt"
    defaults.set(try JSONEncoder().encode(manual), forKey: "profile")
    let loaded = VPNProfile.loadSaved(from: defaults)
    #expect(!loaded.migratedToSSL)
    #expect(loaded.profile == manual)
}

@Test func freshInstallUsesSSLAndAllowsLaterProtocolChoice() throws {
    let suite = "armanVPN.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = VPNProfile.loadSaved(from: defaults)
    #expect(first.profile.tunnel == "SSL")
    #expect(!first.migratedToSSL)
    var manual = first.profile
    manual.tunnel = "IPsec"
    defaults.set(try JSONEncoder().encode(manual), forKey: "profile")
    #expect(VPNProfile.loadSaved(from: defaults).profile == manual)
}

@Test func extractsNestedLoginOptions() throws {
    let fixture = """
    (CCCserverResponse
        :ResponseData (
            :login_options_data (
                :login_options_list (
                    :0 (:id (vpn) :display_name (Standard) :factors (:0 (:factor_type (user_defined))))
                    :1 (:id (vpn_otp) :display_name ("Password + OTP"))
                )
            )
        )
    )
    """
    let options = try SExpression.parse(fixture).loginOptions
    #expect(options == [LoginOption(id: "vpn", title: "Standard"), LoginOption(id: "vpn_otp", title: "Password + OTP")])
}

@Test func rejectsMalformedGatewayReplies() {
    for fixture in ["(", "(reply :id (x)", "(reply) trailing", "(\"unterminated)", String(repeating: "(", count: 65)] {
        #expect(throws: VPNError.self) { try SExpression.parse(fixture) }
    }
}

@Test func decodesServiceStatesAndErrors() throws {
    let disconnected = Data(#"{"ConnectionStatus":"Disconnected"}"#.utf8)
    guard case .disconnected = try EngineClient.decodeStatus(disconnected) else { Issue.record("Wrong status"); return }
    let mfa = Data(#"{"ConnectionStatus":{"Mfa":{"mfa_type":"PasswordInput","prompt":"OTP"}}}"#.utf8)
    guard case .challenge(let kind, let prompt) = try EngineClient.decodeStatus(mfa) else { Issue.record("Missing MFA"); return }
    #expect(kind == "PasswordInput" && prompt == "OTP")
    let failure = Data(#"{"Error":"test failure"}"#.utf8)
    #expect(throws: VPNError.self) { try EngineClient.checkResponse(failure) }
    #expect(throws: VPNError.self) { try EngineClient.decodeStatus(Data(#"{"ConnectionStatus":"Unexpected"}"#.utf8)) }
}

@Test func preservesSubsecondSessionIdentity() throws {
    let first = #"{"ConnectionStatus":{"Connected":{"since":"2026-10-15T11:25:03.123456+05:00","interface_name":"utun7"}}}"#
    let second = first.replacingOccurrences(of: "123456", with: "223456")
    guard case .connected(let a) = try EngineClient.decodeStatus(Data(first.utf8)),
          case .connected(let b) = try EngineClient.decodeStatus(Data(second.utf8)) else { Issue.record("Invalid connected state"); return }
    #expect(a.since != nil)
    #expect(a.session != b.session)
}

@Test func certificateDecisionIsScopedToEndpointAndExactDER() throws {
    let endpoint = "test-\(UUID().uuidString).invalid"
    let certificate = PeerCertificate(endpoint: endpoint, subject: "Test", issuer: "Test", fingerprint: "test",
                                      expires: Date().addingTimeInterval(3600), data: Data([1, 2, 3]),
                                      systemTrusted: false, validationError: "Untrusted")
    let url = try TrustStore.certificateURL(endpoint: endpoint)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try !TrustStore.approved(certificate))
    try TrustStore.save(certificate)
    #expect(try TrustStore.approved(certificate))
    let replacement = PeerCertificate(endpoint: endpoint, subject: "Test", issuer: "Test", fingerprint: "different",
                                      expires: certificate.expires, data: Data([3, 2, 1]), systemTrusted: false, validationError: nil)
    #expect(try !TrustStore.approved(replacement))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func refusesToRememberExpiredCertificate() {
    let certificate = PeerCertificate(endpoint: "expired.invalid", subject: "Expired", issuer: "Test", fingerprint: "test",
                                      expires: Date().addingTimeInterval(-60), data: Data([1]), systemTrusted: false, validationError: nil)
    #expect(throws: VPNError.self) { try TrustStore.save(certificate) }
}

@Test func decodesExactDisconnectReasonAndProcessInstance() throws {
    let payload = Data(#"{"Diagnostics":{"instance":"test-instance","events":[{"sequence":9,"at":"2026-10-15T09:00:00.123456Z","code":"gateway_deleted_sa"},{"sequence":10,"at":"2026-10-15T09:00:01Z","code":"disconnected"}]}}"#.utf8)
    let snapshot = try EngineClient.decodeDiagnostics(payload)
    #expect(snapshot.instance == "test-instance")
    #expect(snapshot.events.map(\.sequence) == [9, 10])
    #expect(snapshot.events[0].date != nil && snapshot.events[1].date != nil)
    #expect(snapshot.events[0].isSpecificDisconnectReason)
    #expect(snapshot.events[0].message.contains("IKE DELETE"))
    #expect(!snapshot.events[1].isSpecificDisconnectReason)
    #expect(throws: VPNError.self) { try EngineClient.decodeDiagnostics(Data(#"{"Error":"unsupported"}"#.utf8)) }
}
