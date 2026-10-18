import Foundation
import Testing
@testable import ArmanVPNCore

@Test func quotaWindowsUseActualDurationAndRemainingPercentage() throws {
    let data = Data(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1792887912},"secondary":{"usedPercent":41,"windowDurationMins":300}},"other":{"limitName":"Other pool","primary":{"usedPercent":120,"windowDurationMins":60}}}}"#.utf8)
    let snapshot = try JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.menuWindow?.percentage == "97%")
    #expect(snapshot.menuWindow?.title == "Неделя")
    #expect(snapshot.windows.first?.remaining == 0)
    #expect(snapshot.windows.first(where: { $0.minutes == 300 })?.remaining == 59)
}

@Test func quotaMissingFieldsAreNotShownAsExhaustedWindows() throws {
    let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":null},"rateLimitsByLimitId":{}}"#.utf8)
    let snapshot = try JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.menuWindow?.percentage == "75%")
    #expect(snapshot.windows[0].resetsAt == nil)
    let empty = try JSONDecoder().decode(CodexUsageSnapshot.self, from: Data(#"{"rateLimits":null}"#.utf8))
    #expect(empty.windows.isEmpty)
    #expect(empty.menuWindow == nil)
}

@Test func smcDecodingPreservesStoppedFansSignedValuesAndRejectsInvalidData() {
    #expect(SMCValueDecoder.number(type: "fpe2", bytes: [0x1f, 0x40]) == 2000)
    #expect(SMCValueDecoder.number(type: "fpe2", bytes: [0, 0]) == 0)
    #expect(SMCValueDecoder.number(type: "sp78", bytes: [0x32, 0x80]) == 50.5)
    #expect(SMCValueDecoder.number(type: "sp78", bytes: [0xff, 0x80]) == -0.5)
    #expect(SMCValueDecoder.number(type: "flt ", bytes: [0, 0, 0x48, 0x42]) == 50)
    #expect(SMCValueDecoder.number(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]) == nil)
    #expect(SMCValueDecoder.number(type: "sp78", bytes: [0]) == nil)
    #expect(SMCValueDecoder.number(type: "other", bytes: [1, 2, 3, 4]) == nil)
}

@Test func sensorGroupsAndExternalFanModesAreExplicit() {
    let snapshot = MacHealthSnapshot(temperatures: [.init(id: "TC0P", celsius: 50), .init(id: "TC0D", celsius: 55),
                                                  .init(id: "Tg0P", celsius: 45), .init(id: "TB0T", celsius: 34)],
                                    fans: [], fanCount: 0, sampledAt: Date())
    #expect(snapshot.cpuTemperature == 55)
    #expect(snapshot.gpuTemperature == 45)
    #expect(FanReading(id: 0, rpm: 0, minimum: 0, maximum: 5000, mode: 1).modeLabel == "Внешнее управление")
}

@Test func menuTemperatureAveragesOnlyValidCPUAndGPUSensors() {
    let snapshot = MacHealthSnapshot(temperatures: [.init(id: "TC0P", celsius: 50), .init(id: "TC0D", celsius: 70),
        .init(id: "TG0P", celsius: 60), .init(id: "TB0T", celsius: 25), .init(id: "TW0P", celsius: 95),
        .init(id: "TC1P", celsius: .nan), .init(id: "TG1P", celsius: 0)], fans: [], fanCount: 0, sampledAt: Date())
    #expect(snapshot.averageProcessorTemperature == 60)
    let unavailable = MacHealthSnapshot(temperatures: [.init(id: "TB0T", celsius: 25)], fans: [], fanCount: 0, sampledAt: Date())
    #expect(unavailable.averageProcessorTemperature == nil)
}

@Test func menuFanValuesPreserveStoppedMissingAndIndependentReadings() {
    let snapshot = MacHealthSnapshot(temperatures: [], fans: [.init(id: 1, rpm: 1850.3, minimum: 0, maximum: 5500, mode: 0),
        .init(id: 0, rpm: 0, minimum: 0, maximum: 5000, mode: 0)], fanCount: 2, sampledAt: Date())
    #expect(snapshot.menuFanSpeedText == "0/1850")
    #expect(FanReading(id: 0, rpm: .nan, minimum: 0, maximum: 5000, mode: 0).rpmValueText == "—")
    #expect(FanReading(id: 0, rpm: nil, minimum: 0, maximum: 5000, mode: 0).rpmValueText == "—")
    #expect(MacHealthSnapshot(temperatures: [], fans: [], fanCount: nil, sampledAt: Date()).menuFanSpeedText == "—")
    #expect(MacHealthSnapshot(temperatures: [], fans: [], fanCount: 0, sampledAt: Date()).menuFanSpeedText == "нет")
}

@Test func manyFanMenuUsesMaximumWhileKeepingFullReadingsAvailable() {
    let fans = [0, 1, 2].map { FanReading(id: $0, rpm: Double(1800 + $0 * 200), minimum: 0, maximum: 5500, mode: 0) }
    let snapshot = MacHealthSnapshot(temperatures: [], fans: fans, fanCount: 3, sampledAt: Date())
    #expect(snapshot.menuFanSpeedText == "2200 max")
    #expect(snapshot.fans.count == 3)
}

@Test func codexIntegrationInitializesBeforeReadingLimitsAndNeverStartsATurn() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    initialized=no
    while IFS= read -r request; do
      case "$request" in
        *'"initialize"'*) printf '%s\n' '{"id":1,"result":{"userAgent":"test"}}' ;;
        *'"initialized"'*) initialized=yes ;;
        *'account'*'rateLimits'*'read'*)
          if [ "$initialized" = yes ]; then
            printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":9,"windowDurationMins":10080}}}}'
          else exit 2; fi ;;
        *) exit 3 ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let result = try CodexUsageService.fetch(executable: executable, timeout: 3)
    #expect(result.menuWindow?.percentage == "91%")
}

@Test func codexIntegrationHasABoundedTimeout() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("fake-codex")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let start = Date()
    #expect(throws: VPNError.self) { try CodexUsageService.fetch(executable: executable, timeout: 0.2) }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func codexEarlyExitIsAnErrorInsteadOfCrashingTheHost() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("fake-codex")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    #expect(throws: VPNError.self) { try CodexUsageService.fetch(executable: executable, timeout: 1) }
}
