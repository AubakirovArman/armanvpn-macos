import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class CoolingController {
    var selectedMode = CoolingMode.system
    var manualTargets: [Int: Double] = [:]
    var startTemperature = 50.0
    var fullTemperature = 80.0
    var status: CoolingStatus?
    var error: String?
    var busy = false
    private(set) var ownsSession = false
    var serviceLabel = CoolingService.label
    private let owner = UUID()
    private var generation = 0
    private var lastErrorWasConnection = false
    private var sleepObserver: NSObjectProtocol?

    static var runningFanUtilities: [String] {
        let ids = ["com.tunabellysoftware.tgpro", "com.crystalidea.MacsFanControl", "eu.exelban.Stats"]
        return NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
            .map { $0.localizedName ?? "другая программа охлаждения" }
    }

    init(observeSleep: Bool = true) {
        if observeSleep {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.returnToSystem() }
            }
        }
    }

    func target(for fan: FanReading) -> Double {
        guard let maximum = fan.maximum, maximum.isFinite, maximum > 0 else { return 0 }
        let minimum = max(fan.minimum ?? 0, min(1200, maximum))
        return min(maximum, max(minimum, manualTargets[fan.id] ?? 2000))
    }

    func registerService() {
        lastErrorWasConnection = false
        do { try CoolingService.register(); serviceLabel = CoolingService.label; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func unregisterService() async {
        guard !ownsSession, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await CoolingService.service.unregister()
            status = nil; error = nil; lastErrorWasConnection = false
            serviceLabel = CoolingService.label
        } catch { self.error = error.localizedDescription }
    }

    func apply(fans: [FanReading]) async {
        guard !busy else { return }
        lastErrorWasConnection = false
        let utilities = Self.runningFanUtilities
        guard selectedMode == .system || utilities.isEmpty else {
            error = "Завершите \(utilities.joined(separator: ", ")), чтобы две программы не управляли вентиляторами одновременно. Мониторинг можно оставить включённым."
            return
        }
        busy = true; defer { busy = false }
        generation += 1
        do {
            try CoolingService.register(); serviceLabel = CoolingService.label
            guard CoolingService.service.status == .enabled else {
                throw VPNError.message("Разрешите службу охлаждения в открытых настройках macOS, затем снова нажмите «Применить».")
            }
            if selectedMode != .system {
                let installed = try await request(CoolingRequest(command: .status))
                guard installed.algorithmVersion == 2 else {
                    throw VPNError.message("Работает прежняя служба охлаждения. Верните системный режим, выберите «Служба → Удалить службу охлаждения», затем разрешите службу заново.")
                }
            }
            let policy = CoolingPolicy(mode: selectedMode, targets: selectedMode == .manual ? Dictionary(uniqueKeysWithValues: fans.map { ($0.id, target(for: $0)) }) : [:],
                                       startTemperature: startTemperature, fullTemperature: fullTemperature)
            try policy.validate()
            status = try await request(CoolingRequest(command: .apply, owner: owner, policy: policy))
            ownsSession = status?.controlling == true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        serviceLabel = CoolingService.label
        guard !busy, CoolingService.service.status == .enabled else { return }
        busy = true; defer { busy = false }
        let currentGeneration = generation
        do {
            let fresh = try await request(CoolingRequest(command: ownsSession ? .heartbeat : .status, owner: owner))
            guard currentGeneration == generation else { return }
            status = fresh
            if lastErrorWasConnection { error = nil; lastErrorWasConnection = false }
            if status?.controlling != true { ownsSession = false }
            if ownsSession { error = nil }
        } catch {
            guard currentGeneration == generation else { return }
            ownsSession = false
            status = nil
            lastErrorWasConnection = true
            self.error = error.localizedDescription
        }
    }

    func returnToSystem() async {
        guard ownsSession else { return }
        generation += 1
        // A release can run while a status request is in flight; the daemon serializes both.
        do {
            status = try await request(CoolingRequest(command: .release, owner: owner))
            ownsSession = false; selectedMode = .system; error = nil
            lastErrorWasConnection = false
        } catch { self.error = error.localizedDescription }
    }

    private func request(_ request: CoolingRequest) async throws -> CoolingStatus {
        try await Task.detached(priority: .utility) { try CoolingIPC.exchange(request) }.value
    }
}

@MainActor
final class CoolingAppDelegate: NSObject, NSApplicationDelegate {
    static weak var cooling: CoolingController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cooling = Self.cooling, cooling.ownsSession else { return .terminateNow }
        Task { await cooling.returnToSystem(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
