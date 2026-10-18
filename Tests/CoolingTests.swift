import Darwin
import Foundation
import Testing
@testable import ArmanVPNCore

private final class FakeCoolingHardware: CoolingHardware {
    var temperature: Double? = 60
    var fans = [CoolingFan(id: 0, minimum: 0, maximum: 5000, actual: 1800, target: 0, forced: false),
                CoolingFan(id: 1, minimum: 0, maximum: 5500, actual: 1800, target: 0, forced: false)]
    var marker = false
    var resets = 0
    var failWrite = false
    var failReset = false
    var delayedReadbacks = 0
    private var remainingStaleReadbacks = 0
    private var staleFans: [CoolingFan] = []
    func sample() throws -> CoolingSample {
        if remainingStaleReadbacks > 0 {
            remainingStaleReadbacks -= 1
            return CoolingSample(fans: staleFans, temperature: temperature)
        }
        return CoolingSample(fans: fans, temperature: temperature)
    }
    func takeControl() throws {
        fans = fans.map { .init(id: $0.id, minimum: $0.minimum, maximum: $0.maximum, actual: $0.actual, target: $0.target, forced: true) }
    }
    func setTargets(_ targets: [Int: Double]) throws {
        staleFans = fans; remainingStaleReadbacks = delayedReadbacks
        for index in fans.indices {
            let fan = fans[index]
            fans[index] = .init(id: fan.id, minimum: fan.minimum, maximum: fan.maximum, actual: fan.actual, target: targets[fan.id]!, forced: fan.forced)
            if failWrite { throw VPNError.message("Simulated partial hardware failure") }
        }
    }
    func restoreSystem() throws {
        resets += 1
        if failReset { throw VPNError.message("Simulated reset failure") }
        remainingStaleReadbacks = 0
        fans = fans.map { .init(id: $0.id, minimum: $0.minimum, maximum: $0.maximum, actual: $0.actual, target: 0, forced: false) }
    }
    func markOwnership() throws { marker = true }
    func clearOwnership() throws { marker = false }
}

@Test func coolingWaitsForAsynchronousSMCAcknowledgement() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    hardware.delayedReadbacks = 3
    let engine = CoolingEngine(hardware: hardware)
    let status = try engine.handle(manualRequest(owner: owner), now: 0)
    #expect(status.controlling)
    #expect(status.fans.allSatisfy { $0.forced && $0.target >= 2000 })
    #expect(hardware.resets == 0)
    try engine.shutdown()
}

@Test func coolingUnconfirmedWriteHasBoundedWaitAndReturnsToSystem() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    hardware.delayedReadbacks = .max
    let engine = CoolingEngine(hardware: hardware)
    let started = ContinuousClock.now
    #expect(throws: VPNError.self) { try engine.handle(manualRequest(owner: owner), now: 0) }
    #expect(started.duration(to: .now) < .seconds(4))
    #expect(!hardware.marker)
    #expect(hardware.fans.allSatisfy { !$0.forced })
}

private func manualRequest(owner: UUID) -> CoolingRequest {
    .init(command: .apply, owner: owner, policy: .init(mode: .manual, targets: [0: 2000, 1: 2100]))
}

@Test func coolingManualLeaseExpiresWithoutUIAndReturnsAllFansToSystem() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    let engine = CoolingEngine(hardware: hardware)
    #expect(try engine.handle(manualRequest(owner: owner), now: 0).controlling)
    #expect(hardware.marker)
    engine.tick(now: 14.9)
    #expect(hardware.fans.allSatisfy { $0.forced })
    engine.tick(now: 15)
    #expect(!hardware.marker)
    #expect(hardware.fans.allSatisfy { !$0.forced })
    let status = try engine.handle(.init(command: .status), now: 16)
    #expect(status.policy.mode == .system)
    #expect(!status.controlling)
    #expect(status.message != nil)
}

@Test func coolingHeartbeatsExtendOnlyTheirOwnLease() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    let engine = CoolingEngine(hardware: hardware)
    _ = try engine.handle(manualRequest(owner: owner), now: 0)
    #expect(throws: VPNError.self) { try engine.handle(.init(command: .heartbeat, owner: UUID()), now: 10) }
    _ = try engine.handle(.init(command: .heartbeat, owner: owner), now: 12)
    engine.tick(now: 20)
    #expect(hardware.marker)
    engine.tick(now: 27)
    #expect(!hardware.marker)
}

@Test func coolingThermalOverrideHasHysteresisAndSlowRampDown() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    hardware.temperature = 86
    let engine = CoolingEngine(hardware: hardware)
    #expect(try engine.handle(manualRequest(owner: owner), now: 0).thermalOverride)
    #expect(hardware.fans[0].target == 5000)
    hardware.temperature = 83
    engine.tick(now: 2)
    #expect(hardware.fans[0].target == 5000)
    hardware.temperature = 79
    engine.tick(now: 4)
    #expect(hardware.fans[0].target == 4800)
    #expect(try !engine.handle(.init(command: .status), now: 4).thermalOverride)
}

@Test func coolingPartialHardwareWriteRollsBackEveryFan() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    hardware.failWrite = true
    let engine = CoolingEngine(hardware: hardware)
    #expect(throws: VPNError.self) { try engine.handle(manualRequest(owner: owner), now: 0) }
    #expect(!hardware.marker)
    #expect(hardware.resets == 1)
    #expect(hardware.fans.allSatisfy { !$0.forced })
}

@Test func coolingSensorFailureAndExternalChangesReleaseControl() throws {
    for failure in ["temperature", "external"] {
        let hardware = FakeCoolingHardware(), owner = UUID()
        let engine = CoolingEngine(hardware: hardware)
        _ = try engine.handle(manualRequest(owner: owner), now: 0)
        if failure == "temperature" { hardware.temperature = nil }
        else { try hardware.setTargets([0: 3000, 1: 3100]) }
        engine.tick(now: 3)
        #expect(!hardware.marker)
        #expect(hardware.fans.allSatisfy { !$0.forced })
    }
}

@Test func coolingRecoveryIsRetriedIfSystemResetTemporarilyFails() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    let engine = CoolingEngine(hardware: hardware)
    _ = try engine.handle(manualRequest(owner: owner), now: 0)
    hardware.failReset = true
    engine.tick(now: 16)
    #expect(hardware.marker)
    hardware.failReset = false
    engine.tick(now: 17)
    #expect(!hardware.marker)
    #expect(hardware.fans.allSatisfy { !$0.forced })
}

@Test func coolingShutdownAndSystemSelectionReleaseHardware() throws {
    let hardware = FakeCoolingHardware(), owner = UUID()
    let engine = CoolingEngine(hardware: hardware)
    _ = try engine.handle(manualRequest(owner: owner), now: 0)
    try engine.shutdown()
    #expect(!hardware.marker)
    _ = try engine.handle(manualRequest(owner: owner), now: 1)
    _ = try engine.handle(.init(command: .apply, policy: .init(mode: .system)), now: 2)
    #expect(!hardware.marker)
    #expect(hardware.fans.allSatisfy { !$0.forced })
}

@Test func coolingCurveUsesValidatedLimitsAndRejectsMissingOrUnsafeTargets() throws {
    let hardware = FakeCoolingHardware()
    var sample = try hardware.sample()
    let automatic = CoolingPolicy(mode: .automatic)
    let targets = try CoolingMath.targets(policy: automatic, sample: sample, override: false)
    #expect(targets[0] == 1667)
    #expect(targets[1] == 1833)
    let incomplete = CoolingPolicy(mode: .manual, targets: [0: 2000])
    #expect(throws: VPNError.self) { try CoolingMath.targets(policy: incomplete, sample: sample, override: false) }
    let tooSlow = CoolingPolicy(mode: .manual, targets: [0: 0, 1: 0])
    #expect(throws: VPNError.self) { try CoolingMath.targets(policy: tooSlow, sample: sample, override: false) }
    sample = .init(fans: sample.fans, temperature: nil)
    #expect(throws: VPNError.self) { try CoolingMath.targets(policy: automatic, sample: sample, override: false) }
    #expect(throws: VPNError.self) { try CoolingPolicy(mode: .automatic, startTemperature: .nan).validate() }
    #expect(throws: VPNError.self) { try CoolingPolicy(mode: .automatic, startTemperature: 70, fullTemperature: 75).validate() }
}

@Test func coolingEncodesOnlySupportedFiniteSMCValues() {
    for type in ["flt ", "fpe2"] {
        let bytes = SMCValueEncoder.bytes(type: type, value: 2345)!
        #expect(SMCValueDecoder.number(type: type, bytes: bytes) == 2345)
    }
    #expect(SMCValueEncoder.bytes(type: "ui8 ", value: 1) == [1])
    #expect(SMCValueEncoder.bytes(type: "ui16", value: 258) == [1, 2])
    #expect(SMCValueEncoder.bytes(type: "ui8 ", value: 256) == nil)
    #expect(SMCValueEncoder.bytes(type: "flt ", value: .infinity) == nil)
    #expect(SMCValueEncoder.bytes(type: "fpe2", value: 16384) == nil)
    #expect(SMCValueEncoder.bytes(type: "unknown", value: 2000) == nil)
}

@Test func coolingIPCRejectsOversizedPacketsBeforeAllocationOrDecode() throws {
    var sockets: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { close(sockets[0]); close(sockets[1]) }
    CoolingIPC.configure(sockets[0], timeout: 1)
    var size = UInt32(CoolingIPC.maximumPacket + 1).bigEndian
    _ = withUnsafeBytes(of: &size) { Darwin.send(sockets[1], $0.baseAddress, $0.count, 0) }
    #expect(throws: VPNError.self) { try CoolingIPC.receive(from: sockets[0]) }
    #expect(throws: VPNError.self) { try CoolingIPC.send(Data(repeating: 0, count: CoolingIPC.maximumPacket + 1), to: sockets[0]) }
}
