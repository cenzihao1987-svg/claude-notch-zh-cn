import Foundation

/// A historical snapshot, not a request to recalculate an old event with today's rules.
struct GuardLoggedRisk: Codable, Equatable, Sendable {
    let systemTotal: Int?
    let configuredTotal: Int?
    let networkPoints: Int?
    let minimumTotal: Int
    let behavior: GuardNetworkBehavior.Kind?
    let locationUnverified: Bool
    var desktopActivity: GuardDesktopActivity? = nil
}

struct GuardNetworkLogEntry: Codable, Equatable, Sendable, Identifiable {
    var recordID: UUID? = nil
    let kind: String
    let exit: GuardExit
    var recordedAt: Date? = nil
    var previous: GuardExit? = nil
    var risk: GuardLoggedRisk? = nil
    var previousRisk: GuardLoggedRisk? = nil
    var sourceOffset: UInt64? = nil
    private enum CodingKeys: String, CodingKey { case recordID, kind, exit, recordedAt, previous, risk, previousRisk }
    var date: Date { recordedAt ?? exit.observedAt }
    var id: String { sourceOffset.map { "journal-\($0)" } ?? recordID?.uuidString ?? "\(date.timeIntervalSince1970)-\(kind)-\(exit.ip)" }

    func title(_ language: AppLanguage) -> String {
        switch kind {
        case "tool-start": language.text("工具启动", "Tool started")
        case "exit-change": language.text("IP 出口变化", "Exit IP changed")
        case "risk-change": language.text("风险变化", "Risk changed")
        case "usage-change": language.text("Claude 运行状态变化", "Claude activity changed")
        case "rule-updated": language.text("运行期计分规则更新", "Exposure scoring updated")
        case "check-failed": language.text("出口检测失败", "Exit check failed")
        case "user-ignored": language.text("已忽略本次提醒", "Warning ignored")
        case "user-confirmed": language.text("已确认新出口", "Exit confirmed")
        default: language.text("出口记录", "Exit observation")
        }
    }

    var isValid: Bool {
        let exits = [exit] + [previous].compactMap { $0 }
        guard kind.utf8.count <= 64, exits.allSatisfy({ GuardExit.normalizedIP($0.ip) != nil }) else { return false }
        // Country codes and score ranges must be validated before displaying file data.
        guard exits.allSatisfy({ item in Locale.Region.isoRegions.contains { $0.identifier == item.country } }) else { return false }
        return [risk, previousRisk].compactMap { $0 }.allSatisfy { value in
            [value.systemTotal, value.configuredTotal].compactMap { $0 }.allSatisfy { (0...100).contains($0) }
                && (value.networkPoints.map { (0...40).contains($0) } ?? true)
                && (0...100).contains(value.minimumTotal)
        }
    }
}

struct GuardNetworkLogPage: Sendable {
    let entries: [GuardNetworkLogEntry]
    let nextOffset: UInt64?
    var skippedRecords = 0
}
