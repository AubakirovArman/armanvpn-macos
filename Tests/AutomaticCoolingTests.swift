import Foundation
import Testing
@testable import ArmanVPNCore

private let automaticPolicy = CoolingPolicy(mode: .automatic, startTemperature: 55, fullTemperature: 80)
private func autoSample(_ temperature: Double?, actual: Double = 1499) -> CoolingSample {
    CoolingSample(fans: [CoolingFan(id: 0, minimum: 1499, maximum: 5348, actual: actual, target: 1499, forced: true),
                        CoolingFan(id: 1, minimum: 1499, maximum: 5776, actual: actual, target: 1499, forced: true)],
                  temperature: temperature)
}

@Test func automaticSingleSpikeDoesNotCauseFullSpeedButSustainedHeatDoesRamp() throws {
    var control = AutomaticCooling()
    var targets = try control.targets(policy: automaticPolicy, sample: autoSample(60), thermalOverride: false, previous: [:], now: 0)
    let initial = targets[0]!
    targets = try control.targets(policy: automaticPolicy, sample: autoSample(75), thermalOverride: false, previous: targets, now: 1)
    #expect(targets[0]! - initial < 250)
    for second in 2...20 {
        targets = try control.targets(policy: automaticPolicy, sample: autoSample(60), thermalOverride: false, previous: targets, now: Double(second))
    }
    #expect(targets[0]! < 1800)
    for second in 21...50 {
        targets = try control.targets(policy: automaticPolicy, sample: autoSample(75), thermalOverride: false, previous: targets, now: Double(second))
    }
    #expect(targets[0]! > 3700)
    #expect(targets[1]! > targets[0]!)
}

@Test func automaticJitterDoesNotHuntAndCoolCurveUsesHardwareMinimum() throws {
    var control = AutomaticCooling()
    var targets = try control.targets(policy: automaticPolicy, sample: autoSample(65), thermalOverride: false, previous: [:], now: 0)
    let initial = targets
    for second in 1...120 {
        let raw = second.isMultiple(of: 2) ? 65.4 : 64.6
        targets = try control.targets(policy: automaticPolicy, sample: autoSample(raw), thermalOverride: false, previous: targets, now: Double(second))
        #expect(targets == initial)
    }
    for raw in [40.0, 50, 55] {
        let target = try CoolingMath.targets(policy: automaticPolicy, sample: autoSample(raw), override: false)
        #expect(target == [0: 1499, 1: 1499])
    }
    let warm = try CoolingMath.targets(policy: automaticPolicy, sample: autoSample(67), override: false)
    #expect(warm[0]! < 2500 && warm[1]! < 2500)
}

@Test func automaticHotPathBypassesFilterAndRampThenCoolsGradually() throws {
    for hot in [80.0, 86.0] {
        var control = AutomaticCooling()
        var targets = try control.targets(policy: automaticPolicy, sample: autoSample(50), thermalOverride: false, previous: [:], now: 0)
        targets = try control.targets(policy: automaticPolicy, sample: autoSample(hot), thermalOverride: hot >= 85, previous: targets, now: 0.1)
        #expect(targets == [0: 5348, 1: 5776])
        let cooled = try control.targets(policy: automaticPolicy, sample: autoSample(60), thermalOverride: false, previous: targets, now: 1.1)
        #expect(cooled[0]! >= 5198)
    }
}

@Test func automaticValidatesRawSensorEvenWhenFilterHasValidHistory() throws {
    for invalid in [nil, Double.nan, .infinity, 0, 126] {
        var control = AutomaticCooling()
        let targets = try control.targets(policy: automaticPolicy, sample: autoSample(60), thermalOverride: false, previous: [:], now: 0)
        #expect(throws: VPNError.self) {
            try control.targets(policy: automaticPolicy, sample: autoSample(invalid), thermalOverride: false, previous: targets, now: 1)
        }
    }
}

@Test func automaticUsesElapsedTimeAndNeverDropsExistingSpeedOnTakeover() throws {
    for interval in [0.25, 0.5, 1.0] {
        var control = AutomaticCooling()
        var targets = try control.targets(policy: automaticPolicy, sample: autoSample(55, actual: 4000), thermalOverride: false, previous: [:], now: 0)
        #expect(targets[0] == 4000)
        for step in 1...Int(4 / interval) {
            targets = try control.targets(policy: automaticPolicy, sample: autoSample(55), thermalOverride: false,
                                          previous: targets, now: Double(step) * interval)
        }
        #expect(abs(targets[0]! - 3400) <= 10)
    }
    var control = AutomaticCooling()
    let targets = try control.targets(policy: automaticPolicy, sample: autoSample(55, actual: 4000), thermalOverride: false, previous: [:], now: 0)
    let late = try control.targets(policy: automaticPolicy, sample: autoSample(55), thermalOverride: false, previous: targets, now: 10)
    #expect(late[0] == 3700) // A late observation is not ten seconds of known cooling.
}
