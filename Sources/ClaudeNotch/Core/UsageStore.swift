import Foundation

/// Aggregates parsed events from every log file into a render-ready snapshot.
final class UsageStore {
    private var eventsByFile: [URL: [UsageEvent]] = [:]

    func ingest(fileURL: URL) throws {
        eventsByFile[fileURL] = try LogParser.parse(fileURL: fileURL)
    }

    /// Store already-parsed events for a file (used when parsing happened off-main), replacing
    /// whatever was there — for full/fresh reads.
    func ingest(fileURL: URL, events: [UsageEvent]) {
        eventsByFile[fileURL] = events
    }

    /// Append newly-tailed events to a file's existing set (for incremental reads).
    func append(fileURL: URL, events: [UsageEvent]) {
        guard !events.isEmpty else { return }
        eventsByFile[fileURL, default: []].append(contentsOf: events)
    }

    func remove(fileURL: URL) { eventsByFile[fileURL] = nil }

    private func allEvents() -> [UsageEvent] {
        var seen = Set<String>()
        var out: [UsageEvent] = []
        for e in eventsByFile.values.flatMap({ $0 })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            if seen.insert(e.dedupeKey).inserted { out.append(e) }
        }
        return out
    }

    func snapshot(now: Date, titles: [String: String] = [:]) -> UsageSnapshot {
        let events = allEvents()
        guard !events.isEmpty else { return .empty }

        let cal = Calendar.current
        let today = events.filter { cal.isDate($0.timestamp, inSameDayAs: now) }

        let tokensToday = today.reduce(0) { $0 + $1.totalTokens }
        let costToday = today.reduce(0) { $0 + PricingTable.cost(for: $1) }

        // 近期任务列表：按滚动 24 小时取，不按自然日。
        // 自然日会让应用连续开着跨过午夜时列表在 00:00 整个清空——刚才还在跑的任务
        // 只因日期翻页就消失，而这正是最想接着往下干的时候。
        // 上面的「今日 Token / 花费」保持自然日口径不变，那是用量统计，翻页归零是对的。
        //
        // 按 sessionId 归组（子 agent 折进父任务，中途 `cd` 不会把一段对话拆成两条），
        // 名字取侧边栏标题，取不到就用项目目录名。
        let recent = events.filter { now.timeIntervalSince($0.timestamp) < 24 * 3_600 }
        var bySession: [String: (cost: Double, tokens: Int, last: Date, cwd: String)] = [:]
        for e in recent {
            var u = bySession[e.sessionId] ?? (0, 0, .distantPast, e.cwd)
            u.cost += PricingTable.cost(for: e)
            u.tokens += e.totalTokens
            if e.timestamp > u.last { u.last = e.timestamp; u.cwd = e.cwd }
            bySession[e.sessionId] = u
        }
        let recentProjects = bySession.map { sid, v -> ProjectUsage in
            let name = titles[sid] ?? (v.cwd.isEmpty ? "session" : (v.cwd as NSString).lastPathComponent)
            return ProjectUsage(id: sid, name: name, cost: v.cost, tokens: v.tokens,
                                last: v.last, cwd: v.cwd)
        }.sorted { $0.last > $1.last }

        var byModel: [String: Int] = [:]
        for e in today { byModel[e.model, default: 0] += e.totalTokens }
        let topModel = byModel.max { $0.value < $1.value }?.key

        // The current session's *whole-life* running total (not today-scoped), so a long chat's
        // accumulating spend is visible as it grows.
        let activeSession = events.last?.sessionId
        let activeEvents = events.filter { $0.sessionId == activeSession }
        let activeSessionTokens = activeEvents.reduce(0) { $0 + $1.totalTokens }
        let activeSessionCost = activeEvents.reduce(0) { $0 + PricingTable.cost(for: $1) }

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let weeklyTokens = events
            .filter { $0.timestamp >= weekAgo }
            .reduce(0) { $0 + $1.totalTokens }

        let blocks = BlockCalculator.blocks(from: events)
        let active = blocks.last.flatMap { $0.contains(now) ? $0 : nil }
        let maxBlockTokens = blocks.map(\.totalTokens).max() ?? 0
        // With only one block the active block IS the largest one, so the ratio is 1.0 by
        // construction — a hard-coded 100% dressed up as a measurement. Since the log window is
        // just the last two days, one block is the normal case for anyone who used Claude
        // recently. Report nothing rather than a number that is always wrong.
        let estimate: Double? = blocks.count >= 2 && maxBlockTokens > 0
            ? min(1, Double(active?.totalTokens ?? 0) / Double(maxBlockTokens)) : nil

        return UsageSnapshot(
            blockRemaining: active?.remaining(at: now),
            blockFractionElapsed: active?.fractionElapsed(at: now) ?? 0,
            blockEnd: active?.end,
            tokensToday: tokensToday,
            costToday: costToday,
            activeSessionTokens: activeSessionTokens,
            activeSessionCost: activeSessionCost,
            weeklyTokens: weeklyTokens,
            recentProjects: recentProjects,
            topModel: topModel,
            blockUsageEstimate: estimate)
    }
}
