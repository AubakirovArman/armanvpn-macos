// SMC wire layout and read protocol adapted from exelban/stats, MIT.
// Copyright (c) 2019 Serhiy Mytrovtsiy. See Legal/Stats-LICENSE.txt.
import Foundation
import IOKit

private struct SMCWireData {
    struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limits {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0, dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
    var index: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCReader {
    private var connection: io_connect_t = 0
    private var info: [UInt32: SMCWireData.KeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw VPNError.message("На этом Mac датчики AppleSMC недоступны.") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            throw VPNError.message("macOS не разрешила чтение датчиков AppleSMC.")
        }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: inout SMCWireData) -> SMCWireData? {
        var output = SMCWireData()
        var outputSize = MemoryLayout<SMCWireData>.stride
        #if COOLING_HELPER
        let commands: [UInt8] = [5, 6, 8, 9]
        #else
        let commands: [UInt8] = [5, 8, 9]
        #endif
        guard commands.contains(input.command),
              IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCWireData>.stride,
                                        &output, &outputSize) == kIOReturnSuccess,
              output.result == 0 else { return nil }
        return output
    }

    func value(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var input = SMCWireData()
        input.key = code
        if info[code] == nil {
            input.command = 9
            guard let result = call(&input), (1...32).contains(result.keyInfo.dataSize) else { return nil }
            info[code] = result.keyInfo
        }
        guard let metadata = info[code] else { return nil }
        input.keyInfo.dataSize = metadata.dataSize
        input.command = 5
        guard var result = call(&input) else { info.removeValue(forKey: code); return nil }
        let bytes = withUnsafeBytes(of: &result.bytes) { Array($0.prefix(Int(metadata.dataSize))) }
        return SMCValueDecoder.number(type: Self.string(metadata.dataType), bytes: bytes)
    }

    func temperatureKeys() -> [String] {
        guard let count = value("#KEY"), count > 0, count <= 20_000 else { return [] }
        var keys: [String] = []
        for index in 0..<Int(count) {
            var input = SMCWireData()
            input.command = 8
            input.index = UInt32(index)
            if let result = call(&input) {
                let key = Self.string(result.key)
                if key.hasPrefix("T"), temperature(key) != nil { keys.append(key) }
            }
        }
        return keys.sorted()
    }

    func metadata(for key: String) -> (type: String, size: UInt32)? {
        guard key.utf8.count == 4 else { return nil }
        _ = value(key)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return info[code].map { (Self.string($0.dataType), $0.dataSize) }
    }

    func temperature(_ key: String) -> Double? {
        guard let value = value(key), value > 0, value < 150 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let metadata = info[code], ["sp78", "flt "].contains(Self.string(metadata.dataType)) else { return nil }
        return value
    }

    #if COOLING_HELPER
    // Compiled only into the privileged cooling helper, never the GUI or VPN core.
    func writeControl(_ key: String, value newValue: Double) throws {
        let fanKey = key.utf8.count == 4 && key.first == "F" && key.dropFirst().first?.isNumber == true &&
            ["md", "Md", "Tg"].contains(String(key.suffix(2)))
        guard fanKey || key == "Ftst", value(key) != nil else {
            throw VPNError.message("Этот ключ управления охлаждением недоступен: \(key).")
        }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let metadata = info[code],
              let bytes = SMCValueEncoder.bytes(type: Self.string(metadata.dataType), value: newValue),
              bytes.count == metadata.dataSize else { throw VPNError.message("Неподдерживаемый формат управления: \(key).") }
        var input = SMCWireData()
        input.key = code; input.command = 6; input.keyInfo.dataSize = metadata.dataSize
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: bytes) }
        // Thermal firmware can temporarily refuse a write during a mode transition.
        for attempt in 0..<20 {
            if call(&input) != nil { return }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.05) }
        }
        throw VPNError.message("macOS отклонила запись управления \(key).")
    }
    #endif

    private static func string(_ value: UInt32) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? ""
    }
}

actor MacHealthService {
    private var reader: SMCReader?
    private var keys: [String]?

    func sample() throws -> MacHealthSnapshot {
        if reader == nil { reader = try SMCReader() }
        guard let reader else { throw VPNError.message("Датчики недоступны.") }
        if keys == nil { keys = reader.temperatureKeys() }
        let temperatures = (keys ?? []).compactMap { key -> TemperatureReading? in
            guard let value = reader.temperature(key) else { return nil }
            return TemperatureReading(id: key, celsius: value)
        }
        let count = reader.value("FNum").flatMap { (0...10).contains($0) ? Int($0) : nil }
        let fans = (0..<(count ?? 0)).map { id in
            FanReading(id: id, rpm: reader.value("F\(id)Ac"), minimum: reader.value("F\(id)Mn"),
                       maximum: reader.value("F\(id)Mx"),
                       mode: (reader.value("F\(id)md") ?? reader.value("F\(id)Md")).map(Int.init))
        }
        return MacHealthSnapshot(temperatures: temperatures, fans: fans, fanCount: count, sampledAt: Date())
    }
}
