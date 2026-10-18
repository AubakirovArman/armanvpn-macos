import Foundation
import Testing
@testable import ArmanVPNCore

@MainActor
private final class AudioHardwareStub: AudioBalanceHardware {
    var current: AudioBalanceOutput? = .init(id: 1, name: "Stereo output", balance: 0.2, writable: true)
    var writes: [UInt32] = []
    var changed: (@MainActor () -> Void)?
    var failsWrite = false
    var refusesWrite = false
    var failsRead = false
    var failsObservation = false
    var replacesOnWrite = false
    func output() throws -> AudioBalanceOutput? {
        if failsRead { throw AudioBalanceError(message: "Read failed") }
        return current
    }
    func center(_ output: AudioBalanceOutput) throws {
        writes.append(output.id)
        if failsWrite { throw AudioBalanceError(message: "Write failed") }
        if replacesOnWrite { current = .init(id: 2, name: "New output", balance: 0.8, writable: true); return }
        if !refusesWrite { current = .init(id: output.id, name: output.name, balance: 0.5, writable: true) }
    }
    func startObserving(_ changed: @escaping @MainActor () -> Void) throws {
        if failsObservation { throw AudioBalanceError(message: "Listener failed") }
        self.changed = changed
    }
    func stopObserving() { changed = nil }
}

@Test @MainActor func balanceOnlyWritesWhenEnabledAndOffCenter() {
    let hardware = AudioHardwareStub()
    let lock = AudioBalanceLock(hardware: hardware)
    lock.refresh()
    #expect(hardware.writes.isEmpty)
    lock.setEnabled(true, monitorChanges: false)
    #expect(hardware.writes == [1])
    #expect(lock.state == .centered)
    for _ in 0..<100 { lock.refresh() }
    #expect(hardware.writes == [1])
    lock.setEnabled(false)
    hardware.current = .init(id: 1, name: "Stereo output", balance: 0.9, writable: true)
    lock.refresh()
    #expect(hardware.current?.balance == 0.9)
    #expect(hardware.writes == [1])
    #expect(lock.state == .off)
}

@Test @MainActor func balanceFollowsNewOutputAndRecoversAfterDisconnect() {
    let hardware = AudioHardwareStub()
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true, monitorChanges: false)
    hardware.current = nil
    lock.refresh()
    #expect(lock.state == .waiting)
    hardware.current = .init(id: 2, name: "Headphones", balance: 0.9, writable: true)
    lock.refresh()
    #expect(hardware.writes == [1, 2])
    #expect(lock.state == .centered)
    #expect(lock.output?.name == "Headphones")
}

@Test @MainActor func balanceSkipsUnsupportedReadOnlyAndInvalidValues() {
    for (value, writable): (Double?, Bool) in [(nil, false), (0.2, false), (.nan, true), (.infinity, true), (-0.1, true), (1.1, true)] {
        let hardware = AudioHardwareStub()
        hardware.current = .init(id: 1, name: "Unsupported", balance: value, writable: writable)
        let lock = AudioBalanceLock(hardware: hardware)
        lock.setEnabled(true, monitorChanges: false)
        #expect(hardware.writes.isEmpty)
        #expect(lock.state == .unsupported)
        #expect(lock.enabled)
    }
}

@Test @MainActor func balanceAcceptsDriverMidpointQuantization() {
    let hardware = AudioHardwareStub()
    hardware.current = .init(id: 1, name: "Quantized", balance: 0.49648577, writable: true)
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true, monitorChanges: false)
    #expect(lock.state == .centered)
    #expect(hardware.writes.isEmpty)
}

@Test @MainActor func balanceReadAndWriteFailuresRecoverWithoutClaimingSuccess() {
    let hardware = AudioHardwareStub()
    let lock = AudioBalanceLock(hardware: hardware)
    hardware.failsRead = true
    lock.setEnabled(true, monitorChanges: false)
    #expect(lock.state == .failed("Read failed"))
    #expect(hardware.writes.isEmpty)
    hardware.failsRead = false
    hardware.failsWrite = true
    lock.refresh(now: 10)
    #expect(lock.state == .failed("Write failed"))
    hardware.failsWrite = false
    lock.refresh(now: 12)
    #expect(lock.state == .centered)
}

@Test @MainActor func balanceRefusedWriteIsVerifiedAndRetriesAreBounded() {
    let hardware = AudioHardwareStub()
    hardware.refusesWrite = true
    let lock = AudioBalanceLock(hardware: hardware)
    let now = ProcessInfo.processInfo.systemUptime
    lock.setEnabled(true, monitorChanges: false)
    if case .failed = lock.state {} else { Issue.record("Must not claim success after an unconfirmed write") }
    for _ in 0..<100 { lock.refresh(now: now + 0.2) }
    #expect(hardware.writes.count == 1)
    lock.refresh(now: now + 2)
    #expect(hardware.writes.count == 2)
}

@Test @MainActor func balanceRouteChangeDuringWriteDoesNotClaimNewDeviceIsCentered() {
    let hardware = AudioHardwareStub()
    hardware.replacesOnWrite = true
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true, monitorChanges: false)
    #expect(lock.state == .waiting)
    #expect(hardware.writes == [1])
    hardware.replacesOnWrite = false
    lock.refresh()
    #expect(lock.state == .centered)
    #expect(hardware.writes == [1, 2])
}

@Test @MainActor func balanceDisableCancelsQueuedCallbacks() async throws {
    let hardware = AudioHardwareStub()
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true)
    let staleCallback = hardware.changed
    hardware.current = .init(id: 2, name: "New route", balance: 0.9, writable: true)
    staleCallback?()
    lock.setEnabled(false)
    staleCallback?()
    try await Task.sleep(for: .milliseconds(250))
    #expect(hardware.writes == [1])
    #expect(hardware.changed == nil)
    #expect(lock.state == .off)
}

@Test @MainActor func balanceNotificationBurstIsCoalesced() async throws {
    let hardware = AudioHardwareStub()
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true)
    hardware.current = .init(id: 2, name: "New route", balance: 0.9, writable: true)
    for _ in 0..<100 { hardware.changed?() }
    try await Task.sleep(for: .milliseconds(300))
    #expect(hardware.writes == [1, 2])
    lock.setEnabled(false)
}

@Test @MainActor func balanceListenerFailureLeavesLockDisabled() {
    let hardware = AudioHardwareStub()
    hardware.failsObservation = true
    let lock = AudioBalanceLock(hardware: hardware)
    lock.setEnabled(true)
    #expect(!lock.enabled)
    #expect(hardware.writes.isEmpty)
    #expect(lock.state == .failed("Listener failed"))
}
