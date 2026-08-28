import Foundation

enum RingState { case ok, warn, critical }

/// One conversation's recent spend, for the sessions list.
struct ProjectUsage: Equatable, Sendable, Identifiable {
    let id: String          // sessionId
    let name: String        // sidebar conversation title, else project folder
    let cost: Double
    let tokens: Int
    let last: Date          // most recent activity in the window
    var cwd: String = ""
}

struct UsageSnapshot: Equatable, Sendable {
    var blockRemaining: TimeInterval?
    var blockFractionElapsed: Double
    var blockEnd: Date?
    var tokensToday: Int
    var costToday: Double
    /// The current (most-recently-active) session's running totals, across its whole life.
    var activeSessionTokens: Int
    var activeSessionCost: Double = 0
    var weeklyTokens: Int = 0
    /// 近 24 小时动过的任务及其花费，最近活跃的排在前面（用于任务列表）。
    /// 刻意不按自然日：应用连续开着跨过午夜时，列表不该在 00:00 清空。
    var recentProjects: [ProjectUsage] = []
    var topModel: String?
    /// Rough fallback usage (0…1): active-block tokens ÷ largest block ever seen.
    /// Used only until the authoritative statusline rate-limit % is available.
    /// nil when there aren't enough blocks for the ratio to mean anything (see UsageStore).
    var blockUsageEstimate: Double?

    var isEmpty: Bool { tokensToday == 0 && blockRemaining == nil }

    var ringState: RingState {
        switch blockFractionElapsed {
        case ..<0.66: return .ok
        case ..<0.85: return .warn
        default:      return .critical
        }
    }

    static let empty = UsageSnapshot(blockRemaining: nil, blockFractionElapsed: 0,
        blockEnd: nil, tokensToday: 0, costToday: 0, activeSessionTokens: 0,
        topModel: nil)
}
