import Foundation

enum CoolingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, automatic, manual
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "Системный"; case .automatic: "Автоматический"; case .manual: "Ручной" }
    }
    var explanation: String {
        switch self {
        case .system: "macOS сама выбирает обороты. armanVPN только показывает датчики."
        case .automatic: "Обороты плавно следуют за нагревом CPU/GPU. Короткие скачки сглаживаются, сильный нагрев обрабатывается сразу."
        case .manual: "Задайте обороты каждого вентилятора. При 85 °C включается максимум до охлаждения ниже 80 °C."
        }
    }
}

struct CoolingPolicy: Codable, Equatable, Sendable {
    var mode: CoolingMode = .system
    var targets: [Int: Double] = [:]
    var startTemperature = 50.0
    var fullTemperature = 80.0

    func validate() throws {
        guard startTemperature.isFinite, fullTemperature.isFinite,
              (40...70).contains(startTemperature), (75...85).contains(fullTemperature),
              fullTemperature - startTemperature >= 10,
              targets.count <= 10,
              targets.allSatisfy({ (0...9).contains($0.key) && $0.value.isFinite && (0...20_000).contains($0.value) }) else {
            throw VPNError.message("Недопустимые параметры охлаждения.")
        }
    }
}

struct CoolingFan: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let minimum: Double
    let maximum: Double
    let actual: Double
    let target: Double
    let forced: Bool
    var controlMinimum: Double { max(minimum, min(1200, maximum)) }
    var valid: Bool {
        [minimum, maximum, actual, target].allSatisfy(\.isFinite) &&
        (0...9).contains(id) && minimum >= 0 && maximum > minimum && maximum <= 20_000 && actual >= 0 && actual <= 25_000
    }
}

struct CoolingSample: Sendable {
    let fans: [CoolingFan]
    let temperature: Double?
    var systemThermalPressure = false
}

struct CoolingStatus: Codable, Sendable {
    // Optional for decoding replies from helpers installed before 1.7.
    var algorithmVersion: Int? = 2
    var policy = CoolingPolicy()
    var fans: [CoolingFan] = []
    var temperature: Double?
    var thermalOverride = false
    var message: String?
    var controlling = false
    var filteredTemperature: Double?
    var controlTemperature: Double?
    var automaticReason: String?
}

struct CoolingRequest: Codable, Sendable {
    enum Command: String, Codable, Sendable { case status, apply, heartbeat, release }
    let command: Command
    var owner: UUID?
    var policy: CoolingPolicy?
}

struct CoolingReply: Codable, Sendable {
    var status: CoolingStatus?
    var error: String?
}

enum CoolingMath {
    static func targets(policy: CoolingPolicy, sample: CoolingSample, override: Bool, controlTemperature: Double? = nil) throws -> [Int: Double] {
        try policy.validate()
        guard !sample.fans.isEmpty, sample.fans.count <= 10, sample.fans.allSatisfy(\.valid),
              Set(sample.fans.map(\.id)).count == sample.fans.count else {
            throw VPNError.message("Нет достоверных данных о вентиляторах.")
        }
        guard let temperature = sample.temperature, temperature.isFinite, (1...125).contains(temperature) else {
            throw VPNError.message("Датчики CPU/GPU недоступны. Управление возвращено macOS.")
        }
        guard !sample.systemThermalPressure else {
            throw VPNError.message("macOS сообщает о сильном тепловом давлении.")
        }
        let curveTemperature = controlTemperature ?? temperature
        guard curveTemperature.isFinite, (1...125).contains(curveTemperature) else {
            throw VPNError.message("Недостоверная температура для расчёта охлаждения.")
        }
        if policy.mode == .manual, Set(policy.targets.keys) != Set(sample.fans.map(\.id)) {
            throw VPNError.message("Задайте обороты всех доступных вентиляторов.")
        }
        if policy.mode == .manual {
            for fan in sample.fans {
                guard let value = policy.targets[fan.id], (fan.controlMinimum...fan.maximum).contains(value) else {
                    throw VPNError.message("Обороты выходят за допустимые границы вентилятора \(fan.id + 1).")
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: try sample.fans.map { fan in
            let target: Double
            if override || temperature >= 85 { target = fan.maximum }
            else if policy.mode == .automatic {
                let fraction = max(0, min(1, (curveTemperature - policy.startTemperature) / (policy.fullTemperature - policy.startTemperature)))
                target = fan.controlMinimum + (fan.maximum - fan.controlMinimum) * fraction * fraction
            } else if policy.mode == .manual {
                guard let value = policy.targets[fan.id], (fan.controlMinimum...fan.maximum).contains(value) else {
                    throw VPNError.message("Обороты выходят за допустимые границы вентилятора \(fan.id + 1).")
                }
                target = value
            } else { throw VPNError.message("Системный режим не задаёт обороты.") }
            return (fan.id, min(fan.maximum, max(fan.controlMinimum, target.rounded())))
        })
    }
}

enum SMCValueEncoder {
    static func bytes(type: String, value: Double) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        switch type {
        case "ui8 " where value <= 255: return [UInt8(value)]
        case "ui16" where value <= 65535:
            let v = UInt16(value); return [UInt8(v >> 8), UInt8(v & 255)]
        case "fpe2" where value <= 16383.75:
            let v = UInt16((value * 4).rounded()); return [UInt8(v >> 8), UInt8(v & 255)]
        case "flt " where value <= 20_000:
            let v = Float(value).bitPattern
            return [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)]
        default: return nil
        }
    }
}
