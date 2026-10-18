import AppKit
import Foundation
import Observation

enum HubSection: String, CaseIterable, Identifiable {
    case overview, vpn, codex, mac, log
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Обзор"; case .vpn: "VPN"; case .codex: "Codex"; case .mac: "Мой Mac"; case .log: "Журнал VPN" }
    }
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .vpn: "network"; case .codex: "sparkles"; case .mac: "desktopcomputer"; case .log: "list.bullet.rectangle" }
    }
    var headline: String {
        switch self {
        case .overview: "Твой Mac.\nВсё рядом."
        case .vpn: "Мощная сеть.\nЛичный подход."
        case .codex: "Знай свой запас."
        case .mac: "Держим руку\nна пульсе."
        case .log: "Всё под контролем."
        }
    }
}

@MainActor @Observable
final class DesktopTools {
    var section = HubSection.overview
    var codex: CodexUsageSnapshot?
    var codexUpdatedAt: Date?
    var codexError: String?
    var codexLoading = false
    var health: MacHealthSnapshot?
    var healthError: String?
    var temperatureHistory: [TemperaturePoint] = []
    var codexEnabled: Bool { didSet {
        if persist { UserDefaults.standard.set(codexEnabled, forKey: "tools.codexEnabled") }
        if !codexEnabled { codex = nil; codexUpdatedAt = nil; codexError = nil }
    } }
    var healthEnabled: Bool { didSet {
        if persist { UserDefaults.standard.set(healthEnabled, forKey: "tools.healthEnabled") }
        if !healthEnabled { health = nil; temperatureHistory = []; healthError = nil }
    } }
    var showCodexInMenu: Bool { didSet { if persist { UserDefaults.standard.set(showCodexInMenu, forKey: "tools.menuCodex") } } }
    var showTemperatureInMenu: Bool { didSet { if persist { UserDefaults.standard.set(showTemperatureInMenu, forKey: "tools.menuTemperature") } } }

    private let persist: Bool
    private let hardware = MacHealthService()
    private var clock = Date()
    private var codexMonitor: Task<Void, Never>?
    private var healthMonitor: Task<Void, Never>?

    init(startMonitoring: Bool = true) {
        persist = startMonitoring
        let defaults = UserDefaults.standard
        codexEnabled = startMonitoring ? defaults.object(forKey: "tools.codexEnabled") as? Bool ?? true : true
        healthEnabled = startMonitoring ? defaults.object(forKey: "tools.healthEnabled") as? Bool ?? true : true
        showCodexInMenu = startMonitoring ? defaults.object(forKey: "tools.menuCodex") as? Bool ?? true : true
        showTemperatureInMenu = startMonitoring ? defaults.object(forKey: "tools.menuTemperature") as? Bool ?? true : true
        if startMonitoring {
            codexMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshCodex()
                    try? await Task.sleep(for: .seconds(120))
                }
            }
            healthMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshHealth()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    var codexIsFresh: Bool {
        guard codexEnabled, let codexUpdatedAt else { return false }
        return clock.timeIntervalSince(codexUpdatedAt) < 600
    }

    var temperatureIsFresh: Bool {
        guard healthEnabled, let health else { return false }
        return clock.timeIntervalSince(health.sampledAt) < 15
    }

    var menuQuota: String { codexIsFresh ? codex?.menuWindow?.percentage ?? "—" : "—" }
    var temperatureLabel: String { health?.cpuTemperature == nil ? "Максимум датчиков" : "CPU" }
    var menuTemperature: String {
        guard temperatureIsFresh, let value = health?.cpuTemperature ?? health?.highestTemperature else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    func refreshCodex() async {
        guard codexEnabled, !codexLoading else { return }
        guard let executable = CodexUsageService.locateExecutable() else {
            codexError = "Установите Codex и войдите в свой аккаунт ChatGPT. Затем нажмите «Обновить»."
            return
        }
        codexLoading = true
        defer { codexLoading = false }
        let job = Task.detached(priority: .utility) { try CodexUsageService.fetch(executable: executable) }
        do {
            let snapshot = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            guard codexEnabled, !Task.isCancelled else { return }
            codex = snapshot
            codexUpdatedAt = Date()
            codexError = snapshot.windows.isEmpty ? "Аккаунт не передал доступные окна лимитов. Это не означает нулевой остаток." : nil
        } catch is CancellationError { }
        catch { codexError = error.localizedDescription }
    }

    func refreshHealth() async {
        clock = Date()
        guard healthEnabled else { return }
        do {
            let sample = try await hardware.sample()
            guard healthEnabled else { return }
            health = sample
            healthError = nil
            if let value = sample.cpuTemperature ?? sample.highestTemperature {
                temperatureHistory.append(TemperaturePoint(date: sample.sampledAt, value: value))
                temperatureHistory = Array(temperatureHistory.suffix(60))
            }
        } catch { healthError = error.localizedDescription }
    }

    func openCodex() {
        let apps = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        if let path = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!) }
    }
}

struct TemperaturePoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}
