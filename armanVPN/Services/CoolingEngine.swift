import Foundation

// The daemon owns the watchdog and temperature policy; the UI never writes SMC.
protocol CoolingHardware: AnyObject {
    func sample() throws -> CoolingSample
    func takeControl() throws
    func setTargets(_ targets: [Int: Double]) throws
    func restoreSystem() throws
    func markOwnership() throws
    func clearOwnership() throws
}

final class CoolingEngine: @unchecked Sendable {
    static let leaseSeconds = 15.0
    private let lock = NSLock()
    private let hardware: any CoolingHardware
    private var owner: UUID?
    private var expiresAt = 0.0
    private var status = CoolingStatus()
    private var expected: [Int: Double] = [:]
    private var ownsHardware = false

    init(hardware: any CoolingHardware) { self.hardware = hardware }

    func handle(_ request: CoolingRequest, now: Double) throws -> CoolingStatus {
        lock.lock(); defer { lock.unlock() }
        if ownsHardware && now >= expiresAt { try restore(message: "Связь с приложением потеряна. Управление возвращено macOS.") }
        switch request.command {
        case .status:
            break
        case .release:
            guard owner == nil || request.owner == owner else { throw VPNError.message("Охлаждением управляет другая копия приложения.") }
            if ownsHardware { try restore(message: nil) }
        case .heartbeat:
            guard let owner, owner == request.owner, ownsHardware else { throw VPNError.message("Сеанс управления завершён. Выберите режим заново.") }
            expiresAt = now + Self.leaseSeconds
        case .apply:
            guard let policy = request.policy else { throw VPNError.message("Не задан режим охлаждения.") }
            try policy.validate()
            if policy.mode == .system {
                // An explicit System action also releases control left by another utility.
                try hardware.restoreSystem()
                try hardware.clearOwnership()
                clearState(message: nil)
            } else {
                guard let token = request.owner else { throw VPNError.message("Нет идентификатора сеанса управления.") }
                guard owner == nil || owner == token else { throw VPNError.message("Охлаждением управляет другая копия приложения.") }
                let sample = try hardware.sample()
                let targets = try CoolingMath.targets(policy: policy, sample: sample, override: false)
                do {
                    try hardware.markOwnership()
                    ownsHardware = true
                    try hardware.takeControl()
                    try hardware.setTargets(targets)
                    _ = try confirmedSample(targets: targets)
                    status.policy = policy
                    status.controlling = true
                    status.thermalOverride = (sample.temperature ?? 0) >= 85
                    status.message = nil
                    expected = targets
                    owner = token
                    expiresAt = now + Self.leaseSeconds
                } catch {
                    try restore(message: "Не удалось применить режим. Управление возвращено macOS.")
                    throw error
                }
            }
        }
        try updateSample()
        return status
    }

    func tick(now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard ownsHardware else { return }
        do {
            if now >= expiresAt { try restore(message: "Приложение не отвечает. Управление возвращено macOS."); return }
            let sample = try hardware.sample()
            try verify(sample, targets: expected)
            guard let temperature = sample.temperature, temperature.isFinite else {
                throw VPNError.message("Датчики температуры недоступны.")
            }
            if temperature >= 85 { status.thermalOverride = true }
            else if temperature < 80 { status.thermalOverride = false }
            var targets = try CoolingMath.targets(policy: status.policy, sample: sample, override: status.thermalOverride)
            // Slow reductions avoid oscillation around temperature thresholds.
            for (id, value) in targets {
                if let previous = expected[id], value < previous { targets[id] = max(value, previous - 200) }
            }
            if targets != expected {
                try hardware.setTargets(targets)
                _ = try confirmedSample(targets: targets)
                expected = targets
            }
            try updateSample()
        } catch {
            do { try restore(message: "\(error.localizedDescription) Управление возвращено macOS.") }
            catch { status.message = "Не удалось вернуть системный режим: \(error.localizedDescription). Повторяем восстановление." }
        }
    }

    func shutdown() throws {
        lock.lock(); defer { lock.unlock() }
        if ownsHardware { try restore(message: nil) }
    }

    private func verify(_ sample: CoolingSample, targets: [Int: Double]) throws {
        guard Set(sample.fans.map(\.id)) == Set(targets.keys),
              sample.fans.allSatisfy({ $0.valid && $0.forced && abs($0.target - (targets[$0.id] ?? -1000)) <= 30 }) else {
            throw VPNError.message("SMC не подтвердил заданные обороты или другая программа изменила режим.")
        }
    }

    private func confirmedSample(targets: [Int: Double]) throws -> CoolingSample {
        // SMC writes are asynchronous. Confirm requested targets/modes, rather
        // than waiting for the physical rotor to reach its new speed.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            let sample = try hardware.sample()
            if (try? verify(sample, targets: targets)) != nil { return sample }
            Thread.sleep(forTimeInterval: 0.05)
        } while ContinuousClock.now < deadline
        throw VPNError.message("SMC не подтвердил режим и заданные обороты за 2 секунды.")
    }

    private func updateSample() throws {
        let sample = try hardware.sample()
        status.fans = sample.fans
        status.temperature = sample.temperature
    }

    private func restore(message: String?) throws {
        // Keep ownership and the recovery marker if even one reset failed.
        try hardware.restoreSystem()
        try hardware.clearOwnership()
        clearState(message: message)
    }

    private func clearState(message: String?) {
        ownsHardware = false; owner = nil; expected = [:]
        status.policy = CoolingPolicy(); status.controlling = false
        status.thermalOverride = false; status.message = message
    }
}
