import AppKit
import Foundation
import Network
import Observation
import OSLog

@MainActor @Observable
final class VPNController {
    var profile: VPNProfile
    var password = ""
    var options: [LoginOption] = []
    var phase = "Отключено"
    var busy = false
    var connected = false
    var details: ConnectionDetails?
    var serviceLabel = BackgroundService.label
    var error: String?
    var certificate: PeerCertificate?
    var challenge: String?
    var challengeAnswer = ""
    var events: [String] = []
    var testStarted: Date?
    var testResult: String?
    var testDrops = 0
    var networkLabel = "Проверяется состояние сети"
    var lastDisconnectReason: String?
    var diagnosticsAvailable = false

    private var wantsConnection = false
    private var connecting = false
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var approvedCertificate: PeerCertificate?
    private var sessionCertificateURL: URL?
    private var activeProfile: VPNProfile?
    private var passwordFactor = 0
    private var usernameSent = false
    private var nextRetry = Date.distantPast
    private var retryCount = 0
    private var generation = UUID()
    private var serviceWasReachable = false
    private var awaitingCertificateForConnect = false
    private var testSession = ""
    private var testInterface = ""
    private let pathMonitor = NWPathMonitor()
    private var previousNetworkState: Bool?
    private var diagnosticsInstance: String?
    private var diagnosticSequence: UInt64 = 0
    private var latestFailure: EngineDiagnosticEvent?

    init(startMonitoring: Bool = true, loadSavedProfile: Bool = true) {
        let loaded = loadSavedProfile ? VPNProfile.loadSaved() : (profile: VPNProfile(), migratedToSSL: false)
        profile = loaded.profile
        if loaded.migratedToSSL {
            log("Сохранённый профиль переведён с IPsec на SSL для обхода обрывов при продлении VPN-адреса. Режим можно изменить в настройках подключения.")
        }
        if startMonitoring {
            pathMonitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let link = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : "Сеть"
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.networkLabel = available ? "\(link): сетевой интерфейс доступен" : "Сетевое подключение отсутствует"
                    if self.previousNetworkState != nil && self.previousNetworkState != available { self.log(self.networkLabel) }
                    self.previousNetworkState = available
                }
            }
            pathMonitor.start(queue: DispatchQueue(label: "armanVPN.network-path"))
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }


    func saveProfile() {
        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = try? JSONEncoder().encode(profile) { UserDefaults.standard.set(data, forKey: "profile") }
    }

    func copyFeedbackDetails() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let report = """
        armanVPN \(version) (\(build)) · Friends Edition
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        RAM: \(ArmanPersonality.current.memoryGB) GB
        Состояние: \(phase)
        Туннель: \(details?.tunnelType ?? profile.tunnel) / \(details?.transport ?? "—")
        Сеть: \(networkLabel)
        Последний разрыв: \(lastDisconnectReason ?? "Не зарегистрирован")
        Тест: \(testResult ?? (testStarted == nil ? "Не запускался" : "Выполняется"))
        Что случилось / пожелание:

        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func setRememberPassword(_ remember: Bool) {
        profile.rememberPassword = remember
        do {
            if remember, !password.isEmpty { try KeychainStore.save(password, for: profile.credentialID) }
            if !remember { try KeychainStore.delete(for: profile.credentialID) }
            saveProfile()
        } catch { self.error = error.localizedDescription }
    }

    func enableService() {
        do {
            try BackgroundService.register()
            serviceLabel = BackgroundService.label
            log("Запрошено разрешение фоновой VPN-службы.")
        } catch { self.error = error.localizedDescription }
    }

    func disableService() {
        guard !connected, !busy else { return }
        run { [self] in
            try await BackgroundService.unregister()
            serviceLabel = BackgroundService.label
            log("Системная VPN-служба удалена из фоновых объектов.")
        }
    }

    func inspectServer() {
        guard !busy, !connected else { return }
        saveProfile()
        run { [self] in
            phase = "Проверка сервера"
            try await prepareServer(connectAfterApproval: false)
        }
    }

    func connect() {
        guard !busy, !connected, challenge == nil, certificate == nil else { return }
        saveProfile()
        wantsConnection = true
        retryCount = 0
        run { [self] in try await startConnection() }
    }

    func disconnect() {
        wantsConnection = false
        generation = UUID()
        operation?.cancel()
        operation = nil
        challenge = nil
        certificate = nil
        connecting = false
        busy = true
        phase = "Отключение"
        Task {
            defer { busy = false }
            do {
                let reply = try await EngineClient.request("Disconnect")
                try EngineClient.checkResponse(reply)
                connected = false
                details = nil
                activeProfile = nil
                phase = "Отключено"
                if testStarted != nil { finishTest(success: false, reason: "Тест остановлен вручную.") }
                log("Соединение отключено пользователем.")
            } catch { self.error = error.localizedDescription }
        }
    }

    func acceptCertificate(remember: Bool) {
        guard let certificate else { return }
        let connectAfter = awaitingCertificateForConnect
        self.certificate = nil
        run { [self] in
            if remember {
                try TrustStore.save(certificate)
                clearTemporaryCertificate()
            } else {
                clearTemporaryCertificate()
                sessionCertificateURL = try TrustStore.temporary(certificate)
            }
            approvedCertificate = certificate
            log("Сертификат сервера принят пользователем.")
            try await loadOptions(certificate)
            if connectAfter { try await startConnection() }
        }
    }

    func rejectCertificate() {
        certificate = nil
        wantsConnection = false
        phase = "Сертификат не принят"
        log("Подключение отменено: сертификат не принят.")
    }

    func sendChallenge() {
        guard let params = activeParameters(), !challengeAnswer.isEmpty else { return }
        let answer = challengeAnswer
        challengeAnswer = ""
        challenge = nil
        run { [self] in
            let response = try await EngineClient.request(["ChallengeCode": [answer, params]], timeout: 120)
            try EngineClient.checkResponse(response)
            try await waitForConnection(generation)
        }
    }

    func cancelChallenge() { disconnect() }

    func startTest() {
        guard connected else { return }
        testStarted = Date()
        testDrops = 0
        testResult = nil
        testSession = details?.session ?? ""
        testInterface = details?.interface ?? ""
        log("Начат тест: 10 минут без разрывов и переподключений.")
    }

    private func startConnection() async throws {
        try profile.validate()
        if case .connected(let existing) = try await EngineClient.status() {
            guard existing.endpoint == profile.endpoint, existing.username == profile.username else {
                throw VPNError.message("Уже активен другой профиль. Сначала отключите его.")
            }
            didConnect(existing)
            return
        }
        phase = "Проверка сертификата"
        try await prepareServer(connectAfterApproval: true)
        guard certificate == nil, let approvedCertificate else { return }
        guard !profile.username.isEmpty, !profile.loginType.isEmpty else { throw VPNError.message("Укажите логин и выберите способ входа.") }
        if password.isEmpty, profile.rememberPassword { password = try KeychainStore.password(for: profile.credentialID) ?? "" }
        guard !password.isEmpty else { throw VPNError.message("Введите пароль VPN.") }
        if profile.rememberPassword { try KeychainStore.save(password, for: profile.credentialID) }
        let token = UUID()
        generation = token
        activeProfile = profile
        passwordFactor = 0
        usernameSent = false
        connecting = true
        defer { connecting = false }
        phase = "Подключение"
        let params = EngineClient.parameters(profile: profile, password: password,
                                              certificate: try sessionCertificateURL ?? TrustStore.certificateURL(endpoint: approvedCertificate.endpoint))
        let reply = try await EngineClient.request(["Connect": params], timeout: 120)
        try Task.checkCancellation()
        guard token == generation else { return }
        try EngineClient.checkResponse(reply)
        log("VPN-служба начала подключение.")
        try await waitForConnection(token)
    }

    private func prepareServer(connectAfterApproval: Bool) async throws {
        if approvedCertificate?.endpoint != profile.endpoint {
            clearTemporaryCertificate()
            approvedCertificate = nil
        }
        let candidate = try await GatewayClient.inspect(profile)
        try Task.checkCancellation()
        guard let expires = candidate.expires, expires > Date() else {
            throw VPNError.message("Сертификат сервера истёк или срок действия неизвестен.")
        }
        let acceptedInSession = approvedCertificate?.endpoint == candidate.endpoint && approvedCertificate?.data == candidate.data
        if try !acceptedInSession && !TrustStore.approved(candidate) {
            certificate = candidate
            awaitingCertificateForConnect = connectAfterApproval
            phase = "Подтвердите сертификат"
            return
        }
        approvedCertificate = candidate
        try await loadOptions(candidate)
    }

    private func loadOptions(_ candidate: PeerCertificate) async throws {
        options = try await GatewayClient.loginOptions(profile, approved: candidate.data)
        if !options.contains(where: { $0.id == profile.loginType }) { profile.loginType = options.first?.id ?? "" }
        saveProfile()
        phase = "Сервер готов к подключению"
        log("Шлюз доступен. Способов входа: \(options.count).")
    }

    private func activeParameters() -> [String: Any]? {
        guard let activeProfile, let url = try? sessionCertificateURL ?? TrustStore.certificateURL(endpoint: activeProfile.endpoint) else { return nil }
        return EngineClient.parameters(profile: activeProfile, password: password, certificate: url)
    }

    private func waitForConnection(_ token: UUID) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            guard token == generation else { return }
            let status = try await EngineClient.status()
            await readDiagnostics()
            switch status {
            case .connected(let details):
                didConnect(details)
                return
            case .disconnected:
                throw VPNError.message("Шлюз завершил подключение. Проверьте учётные данные и выбранный режим.")
            case .connecting:
                break
            case .challenge(let kind, let prompt):
                guard let params = activeParameters() else { return }
                var answer: String?
                if kind == "UserNameInput", !usernameSent {
                    usernameSent = true
                    answer = activeProfile?.username
                } else if kind == "PasswordInput" {
                    passwordFactor += 1
                    if passwordFactor == 1 { answer = password }
                }
                if let answer, !answer.isEmpty {
                    let reply = try await EngineClient.request(["ChallengeCode": [answer, params]], timeout: 120)
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    try EngineClient.checkResponse(reply)
                } else {
                    if kind == "IdentityProvider" || kind == "MobileAccess" {
                        throw VPNError.message("Этот способ входа требует браузерного SSO. В этой версии выберите вход по логину и паролю.")
                    }
                    challenge = prompt
                    phase = "Требуется подтверждение"
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw VPNError.message("Шлюз не завершил подключение за 120 секунд.")
    }

    private func didConnect(_ info: ConnectionDetails) {
        if !connected { log("Туннель подключён: \(info.interface), \(info.transport).") }
        details = info
        connected = true
        phase = "Подключено"
        retryCount = 0
    }

    private func poll() async {
        serviceLabel = BackgroundService.label
        guard !connecting, !busy else { return }
        do {
            let status = try await EngineClient.status()
            await readDiagnostics()
            serviceWasReachable = true
            switch status {
            case .connected(let info):
                if testStarted != nil, info.session != testSession || info.interface != testInterface {
                    recordDrop("Во время теста изменилась VPN-сессия.")
                }
                didConnect(info)
                if let testStarted, Date().timeIntervalSince(testStarted) >= 600 {
                    finishTest(success: testDrops == 0, reason: "600 секунд. Разрывов: \(testDrops).")
                }
            case .disconnected:
                if connected {
                    let reason = currentDisconnectReason()
                    recordDrop("VPN-служба сообщила об отключении. \(reason) Сеть: \(networkLabel).")
                }
                connected = false
                details = nil
                if wantsConnection, profile.reconnect, certificate == nil, challenge == nil, Date() >= nextRetry {
                    run { [self] in try await startConnection() }
                } else if !wantsConnection { phase = "Отключено" }
            case .connecting:
                if connected { recordDrop("VPN-сессия прервалась, служба начала новое подключение. \(currentDisconnectReason())") }
                connected = false
                details = nil
                phase = "Подключение"
            case .challenge: break
            }
        } catch {
            if connected {
                lastDisconnectReason = "Потеряна связь с локальной VPN-службой. Состояние удалённого туннеля неизвестно."
                recordDrop(lastDisconnectReason!)
                connected = false
                details = nil
                phase = "Состояние туннеля неизвестно"
            }
            if serviceWasReachable { serviceWasReachable = false; log("VPN-служба недоступна.") }
        }
    }

    private func readDiagnostics() async {
        guard let snapshot = try? await EngineClient.diagnostics() else { diagnosticsAvailable = false; return }
        diagnosticsAvailable = true
        if snapshot.instance != diagnosticsInstance {
            if diagnosticsInstance != nil { log("VPN-ядро было перезапущено.") }
            diagnosticsInstance = snapshot.instance
            diagnosticSequence = 0
            latestFailure = nil
        }
        for event in snapshot.events where event.sequence > diagnosticSequence {
            diagnosticSequence = event.sequence
            if event.isSpecificDisconnectReason || event.code == "tunnel_error" || event.code == "control_error" {
                if event.isSpecificDisconnectReason || latestFailure?.date.map({ (event.date ?? .now).timeIntervalSince($0) > 5 }) != false {
                    latestFailure = event
                    lastDisconnectReason = event.message
                }
            }
            if event.code != "connected" && event.code != "disconnected" { log(event.message, at: event.date ?? .now) }
        }
    }

    private func currentDisconnectReason() -> String {
        if let failure = latestFailure, let date = failure.date,
           date >= (details?.since ?? .now) {
            return failure.message
        }
        return diagnosticsAvailable ? "Причина завершения туннеля не уточнена ядром." : "Эта версия VPN-ядра не передаёт причину разрыва."
    }

    private func recordDrop(_ message: String) {
        log(message)
        if testStarted != nil {
            testDrops += 1
            finishTest(success: false, reason: "\(message) Автоподключение не засчитывается в тест.")
        }
    }

    private func finishTest(success: Bool, reason: String) {
        testResult = "\(success ? "Тест пройден" : "Тест не пройден"): \(reason)"
        testStarted = nil
        log(testResult!)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        operation = Task { [self] in
            defer { busy = false }
            do { try await action() }
            catch is CancellationError { }
            catch {
                self.error = error.localizedDescription.replacingOccurrences(of: password.isEmpty ? "\0" : password, with: "••••••")
                phase = "Не удалось подключиться"
                if wantsConnection {
                    // Authentication failures require user input; retries must not lock out the account.
                    wantsConnection = false
                    retryCount += 1
                    nextRetry = Date().addingTimeInterval(min(60, pow(2, Double(retryCount))))
                }
                if connecting || activeProfile != nil {
                    _ = try? await EngineClient.request("Disconnect")
                    activeProfile = nil
                }
                log("Операция завершилась ошибкой. Подробности показаны в окне.")
            }
        }
    }

    private func log(_ text: String, at date: Date = .now) {
        Logger(subsystem: "armanibadboy.armanVPN", category: "Connection").notice("\(text, privacy: .public)")
        let stamp = date.formatted(date: .omitted, time: .standard)
        events.insert("\(stamp)  \(text)", at: 0)
        if events.count > 100 { events.removeLast() }
    }

    private func clearTemporaryCertificate() {
        if let url = sessionCertificateURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        sessionCertificateURL = nil
    }
}
