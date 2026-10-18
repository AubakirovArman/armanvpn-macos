import Foundation
import Observation

struct AudioBalanceOutput: Equatable, Sendable {
    let id: UInt32
    let name: String
    let balance: Double?
    let writable: Bool

    // Some drivers quantize the midpoint (for example, 0.496 instead of 0.5).
    var isCentered: Bool { balance.map { $0.isFinite && abs($0 - 0.5) <= 0.005 } ?? false }
    var supportsBalance: Bool { writable && balance.map { $0.isFinite && (0...1).contains($0) } == true }
}

@MainActor
protocol AudioBalanceHardware: AnyObject {
    func output() throws -> AudioBalanceOutput?
    func center(_ output: AudioBalanceOutput) throws
    func startObserving(_ changed: @escaping @MainActor () -> Void) throws
    func stopObserving()
}

enum AudioBalanceState: Equatable {
    case off, waiting, unsupported, centered, correcting, failed(String)
}

/// Runs on one actor, so disabling cannot race a queued audio callback or a write.
@MainActor @Observable
final class AudioBalanceLock {
    private(set) var enabled = false
    private(set) var output: AudioBalanceOutput?
    private(set) var state: AudioBalanceState = .off
    private(set) var corrections = 0
    @ObservationIgnored private let hardware: any AudioBalanceHardware
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastWrite: (id: UInt32, time: TimeInterval)?

    init(hardware: any AudioBalanceHardware) { self.hardware = hardware }

    deinit { monitor?.cancel(); pending?.cancel() }

    func setEnabled(_ enabled: Bool, monitorChanges: Bool = true) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        monitor?.cancel(); monitor = nil
        pending?.cancel(); pending = nil
        hardware.stopObserving()
        lastWrite = nil
        guard enabled else { state = .off; return }
        if monitorChanges {
            do { try hardware.startObserving { [weak self] in self?.scheduleRefresh() } }
            catch {
                self.enabled = false
                hardware.stopObserving()
                state = .failed(error.localizedDescription)
                return
            }
            // Covers missed driver notifications, wake and transient audio-service restarts.
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    self.refresh()
                }
            }
        }
        refresh()
    }

    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        do {
            output = try hardware.output()
            guard let output else { state = .waiting; return }
            guard output.supportsBalance else { state = .unsupported; return }
            guard !output.isCentered else { state = .centered; return }
            // Do not fight another utility or a driver that refuses/quantizes a write.
            if let lastWrite, lastWrite.id == output.id, now - lastWrite.time < 1 {
                state = .correcting
                return
            }
            lastWrite = (output.id, now)
            try hardware.center(output)
            let verified = try hardware.output()
            self.output = verified
            guard let verified, verified.id == output.id else { state = .waiting; return }
            guard verified.isCentered else {
                state = .failed("Устройство пока не подтвердило центральный баланс. Повторим проверку автоматически.")
                return
            }
            corrections += 1
            state = .centered
        } catch { state = .failed(error.localizedDescription) }
    }

    private func scheduleRefresh() {
        guard enabled, pending == nil else { return }
        // Coalesce separate left/right volume notifications into one sample.
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            self.pending = nil
            self.refresh()
        }
    }
}
