import Foundation

struct TemperatureReading: Identifiable, Sendable {
    let id: String
    let celsius: Double
    var group: String {
        if id == "TCGC" { return "GPU" }
        if id.hasPrefix("TC") { return "CPU" }
        #if arch(arm64)
        if id.hasPrefix("Tp") || id.hasPrefix("Te") || id.hasPrefix("Tf0") || id.hasPrefix("Tf4") { return "CPU" }
        if id.hasPrefix("Tf1") || id.hasPrefix("Tf2") { return "GPU" }
        #endif
        if id.hasPrefix("Tg") || id.hasPrefix("TG") { return "GPU" }
        if id.hasPrefix("TB") || id.hasPrefix("Tb") { return "Батарея" }
        return "Другие"
    }
}

struct FanReading: Identifiable, Sendable {
    let id: Int
    let rpm: Double?
    let minimum: Double?
    let maximum: Double?
    let mode: Int?
    var modeLabel: String {
        switch mode {
        case 0, 3: "Автоматически"
        case 1: "Внешнее управление"
        default: "Режим неизвестен"
        }
    }
}

struct MacHealthSnapshot: Sendable {
    let temperatures: [TemperatureReading]
    let fans: [FanReading]
    let fanCount: Int?
    let sampledAt: Date
    var cpuTemperature: Double? { temperatures.filter { $0.group == "CPU" }.map(\.celsius).max() }
    var gpuTemperature: Double? { temperatures.filter { $0.group == "GPU" }.map(\.celsius).max() }
    var highestTemperature: Double? { temperatures.map(\.celsius).max() }
}

enum SMCValueDecoder {
    static func number(type: String, bytes: [UInt8]) -> Double? {
        let result: Double
        switch type {
        case "ui8 " where bytes.count >= 1: result = Double(bytes[0])
        case "ui16" where bytes.count >= 2: result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            result = Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case "sp78" where bytes.count >= 2:
            result = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count >= 2:
            result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt " where bytes.count >= 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            result = Double(Float(bitPattern: bits))
        default: return nil
        }
        return result.isFinite ? result : nil
    }
}
