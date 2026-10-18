import Foundation

/// Time-aware fan curve. Raw readings always retain an independent hot path.
/// Constants and tuning rationale: docs/cooling-control.md.
struct AutomaticCooling {
    private var lastTime: Double?
    private(set) var filteredTemperature: Double?
    private(set) var controlTemperature: Double?
    private(set) var reason = ""

    mutating func targets(policy: CoolingPolicy, sample: CoolingSample, thermalOverride: Bool,
                          previous: [Int: Double], now: Double) throws -> [Int: Double] {
        // Validate raw sensors and limits before filtering can conceal a failure.
        _ = try CoolingMath.targets(policy: policy, sample: sample, override: thermalOverride)
        guard let raw = sample.temperature, now.isFinite,
              lastTime.map({ now >= $0 }) ?? true else {
            throw VPNError.message("Недостоверное время измерения охлаждения.")
        }
        let first = lastTime == nil
        // Do not extrapolate a single late sample over an unobserved long interval.
        let elapsed = min(2, max(0, now - (lastTime ?? now)))
        lastTime = now
        let old = filteredTemperature ?? raw
        let tau = raw > old ? 5.0 : 12.0
        let filtered = first ? raw : old + (1 - exp(-elapsed / tau)) * (raw - old)
        filteredTemperature = filtered
        if controlTemperature == nil || abs(filtered - controlTemperature!) >= 1 || filtered <= policy.startTemperature {
            controlTemperature = filtered
        }

        // Full-temperature threshold bypasses BOTH filtering and slew limits.
        // The separate 85/80 °C latch also protects manual mode.
        if thermalOverride || raw >= policy.fullTemperature {
            filteredTemperature = raw
            controlTemperature = raw
            reason = thermalOverride ? "Температурная защита: максимальные обороты." : "Достигнут порог максимальных оборотов."
            return try CoolingMath.targets(policy: policy, sample: sample, override: true)
        }

        let desired = try CoolingMath.targets(policy: policy, sample: sample, override: false,
                                              controlTemperature: controlTemperature)
        var output: [Int: Double] = [:]
        var rising = false, falling = false
        for fan in sample.fans {
            let target = desired[fan.id]!
            let oldTarget = previous[fan.id] ?? min(fan.maximum, max(fan.controlMinimum, fan.actual))
            let value: Double
            if first {
                // Taking over never abruptly lowers an already-running fan.
                value = max(target, oldTarget)
            } else if target > oldTarget {
                value = min(target, oldTarget + 400 * elapsed)
            } else {
                value = max(target, oldTarget - 150 * elapsed)
            }
            rising = rising || value > oldTarget
            falling = falling || value < oldTarget
            output[fan.id] = min(fan.maximum, max(fan.controlMinimum, value.rounded()))
        }
        if raw - filtered >= 2 {
            reason = "Сглаживаем краткий скачок; при продолжении нагрева обороты вырастут."
        } else if falling || filtered - raw >= 2 {
            reason = "Mac остывает: постепенно снижаем обороты."
        } else if rising {
            reason = "Устойчивый нагрев: плавно повышаем обороты."
        } else {
            reason = "Температура стабильна: удерживаем обороты."
        }
        return output
    }
}
