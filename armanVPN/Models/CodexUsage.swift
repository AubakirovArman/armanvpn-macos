import Foundation

struct CodexUsageSnapshot: Decodable, Sendable {
    let rateLimits: CodexLimitBucket?
    let rateLimitsByLimitId: [String: CodexLimitBucket]?

    var windows: [CodexUsageWindow] {
        let buckets = rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? rateLimits.map { [$0.limitId ?? "codex": $0] } ?? [:]
        return buckets.flatMap { id, bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, value in
                guard let value, value.usedPercent.isFinite, let minutes = value.windowDurationMins, minutes > 0 else { return nil }
                return CodexUsageWindow(id: "\(id):\(slot)", bucket: bucket.limitName ?? id,
                                        usedPercent: value.usedPercent, minutes: minutes,
                                        resetsAt: value.resetsAt.map(Date.init(timeIntervalSince1970:)))
            } as [CodexUsageWindow]
        }.sorted { $0.minutes == $1.minutes ? $0.id < $1.id : $0.minutes < $1.minutes }
    }

    var menuWindow: CodexUsageWindow? {
        let codex = windows.filter { $0.id.hasPrefix("codex:") }
        let candidates = codex.isEmpty ? windows : codex
        return candidates.first(where: { $0.minutes == 10080 }) ?? candidates.first
    }
}

struct CodexLimitBucket: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: CodexLimitWindow?
    let secondary: CodexLimitWindow?
    let planType: String?
}

struct CodexLimitWindow: Decodable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
}

struct CodexUsageWindow: Identifiable, Sendable {
    let id: String
    let bucket: String
    let usedPercent: Double
    let minutes: Int
    let resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var percentage: String { "\(Int(remaining.rounded(.down)))%" }
    var title: String {
        switch minutes {
        case 10080: "Неделя"
        case 1440: "24 часа"
        case 300: "5 часов"
        case let value where value % 60 == 0: "\(value / 60) ч"
        default: "\(minutes) мин"
        }
    }
}
