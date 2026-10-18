// Fan-control protocol adapted from exelban/stats (MIT).
// Copyright (c) 2019 Serhiy Mytrovtsiy. See armanVPN/Legal/Stats-LICENSE.txt.
import Darwin
import Foundation

final class SMCCoolingHardware: CoolingHardware {
    static let recoveryPath = "/var/run/armanvpn-cooling-owned"
    private let reader: SMCReader
    private let temperatureKeys: [String]

    init() throws {
        reader = try SMCReader()
        temperatureKeys = reader.temperatureKeys().filter {
            ["CPU", "GPU"].contains(TemperatureReading(id: $0, celsius: 0).group)
        }
    }

    func sample() throws -> CoolingSample {
        let ids = try fanIDs()
        let fans = try ids.map { id -> CoolingFan in
            guard let minimum = reader.value("F\(id)Mn"), let maximum = reader.value("F\(id)Mx"),
                  let actual = reader.value("F\(id)Ac"), let target = reader.value("F\(id)Tg"),
                  let mode = reader.value(modeKey(id)) else { throw VPNError.message("Не удалось прочитать вентилятор \(id + 1).") }
            return CoolingFan(id: id, minimum: minimum, maximum: maximum, actual: actual, target: target, forced: mode == 1)
        }
        let pressure: Bool
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: pressure = false
        case .serious, .critical: pressure = true
        @unknown default: pressure = true
        }
        return CoolingSample(fans: fans, temperature: temperatureKeys.compactMap { reader.temperature($0) }.max(),
                             systemThermalPressure: pressure)
    }

    func takeControl() throws {
        let ids = try fanIDs()
        let initialFans = try sample().fans
        guard initialFans.allSatisfy(\.valid) else { throw VPNError.message("Неизвестные границы оборотов.") }
        // On M1–M4 the mode write can be acknowledged before thermalmonitord
        // has yielded control. Enable the hardware's test flag first when present.
        if let value = reader.value("Ftst"), value != 1 {
            try reader.writeControl("Ftst", value: 1)
            Thread.sleep(forTimeInterval: 3)
        }
        for id in ids {
            do { try reader.writeControl(modeKey(id), value: 1) }
            catch {
                guard reader.value("Ftst") != nil else { throw error }
                try reader.writeControl("Ftst", value: 1)
                Thread.sleep(forTimeInterval: 3)
                try reader.writeControl(modeKey(id), value: 1)
            }
            if let fan = initialFans.first(where: { $0.id == id }) {
                try reader.writeControl("F\(id)Tg", value: min(fan.maximum, max(fan.actual, max(fan.controlMinimum, 2000))))
            }
        }
    }

    func setTargets(_ targets: [Int: Double]) throws {
        let fans = try sample().fans
        guard Set(targets.keys) == Set(fans.map(\.id)) else { throw VPNError.message("Изменился набор вентиляторов.") }
        for fan in fans {
            guard fan.valid, let target = targets[fan.id], target.isFinite,
                  (fan.controlMinimum...fan.maximum).contains(target) else { throw VPNError.message("Недопустимые обороты.") }
            try reader.writeControl("F\(fan.id)Tg", value: target)
        }
    }

    func restoreSystem() throws {
        let ids = try fanIDs()
        var failures: [String] = []
        if let value = reader.value("Ftst"), value != 0 {
            do { try reader.writeControl("Ftst", value: 0) }
            catch { failures.append(error.localizedDescription) }
        }
        for id in ids {
            do {
                if reader.value(modeKey(id)) == 1 { try reader.writeControl(modeKey(id), value: 0) }
                // Apple Silicon also requires releasing the explicit target;
                // otherwise firmware can keep the previous forced RPM active.
                try reader.writeControl("F\(id)Tg", value: 0)
            } catch { failures.append(error.localizedDescription) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var confirmed = false
        repeat {
            let fans = try sample().fans
            let testReleased = reader.value("Ftst").map { $0 == 0 } ?? true
            if testReleased && !fans.contains(where: \.forced) { confirmed = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        } while ContinuousClock.now < deadline
        if !confirmed { failures.append("SMC не подтвердил системный режим за 2 секунды.") }
        guard failures.isEmpty else { throw VPNError.message(failures.joined(separator: " ")) }
    }

    func recoverIfNeeded() throws {
        var metadata = stat()
        if lstat(Self.recoveryPath, &metadata) == 0 {
            guard metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw VPNError.message("Неверный файл восстановления охлаждения.") }
            try restoreSystem()
            try clearOwnership()
        }
    }

    func markOwnership() throws {
        let fd = open(Self.recoveryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 { defer { close(fd) }; guard fsync(fd) == 0 else { throw VPNError.message("Не удалось сохранить состояние восстановления.") }; return }
        var metadata = stat()
        guard errno == EEXIST, lstat(Self.recoveryPath, &metadata) == 0,
              metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw VPNError.message("Не удалось создать состояние восстановления.") }
    }

    func clearOwnership() throws {
        if unlink(Self.recoveryPath) != 0 && errno != ENOENT { throw VPNError.message("Не удалось завершить восстановление охлаждения.") }
    }

    private func fanIDs() throws -> [Int] {
        guard let count = reader.value("FNum"), count.isFinite, (0...10).contains(count) else { throw VPNError.message("Список вентиляторов недоступен.") }
        return Array(0..<Int(count))
    }

    private func modeKey(_ id: Int) -> String { reader.value("F\(id)md") != nil ? "F\(id)md" : "F\(id)Md" }
}
