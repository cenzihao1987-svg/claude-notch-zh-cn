import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct UsageStoreTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func dedupesAndAggregates() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        #expect(snap.tokensToday == 1_500_000)
        #expect(abs(snap.costToday - 15.40) < 0.0001)
        #expect(snap.topModel == "claude-opus-4-8")
        #expect(snap.blockRemaining != nil)
        #expect(!snap.isEmpty)
    }

    @Test func emptyStoreIsEmptySnapshot() {
        let snap = UsageStore().snapshot(now: Date())
        #expect(snap.isEmpty)
        #expect(snap.tokensToday == 0)
        #expect(snap.blockRemaining == nil)
    }

    /// 2026-08-21 的回归测试：应用连续开着跨过午夜，「近期任务」在 00:00 整个清空，
    /// 直到再开一次 Claude 才回来。原因是任务列表按自然日筛选——刚才还在跑的任务，
    /// 只因为日期翻页就凭空消失了。改成滚动 24 小时窗口。
    ///
    /// 「今日 Token」保持自然日口径不变：那是用量统计，翻页归零是对的。
    @Test func recentTasksSurviveMidnight() {
        let store = UsageStore()
        // 用本地日历定位午夜，测试才不会随时区变结论。
        let midnight = Calendar.current.startOfDay(
            for: ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        )
        let now = midnight.addingTimeInterval(30 * 60)
        // 昨晚 23:50 跑的任务——40 分钟前，日期已经翻页。
        let lastNight = midnight.addingTimeInterval(-10 * 60)
        store.ingest(fileURL: URL(fileURLWithPath: "/tmp/a.jsonl"), events: [
            UsageEvent(timestamp: lastNight, sessionId: "s1", requestId: "r1", messageId: "m1",
                       model: "claude-sonnet-4-5", cwd: "/tmp/project",
                       inputTokens: 100, outputTokens: 200,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])

        let snap = store.snapshot(now: now)

        #expect(snap.recentProjects.map(\.id) == ["s1"])
        #expect(snap.tokensToday == 0)  // 用量仍按自然日
    }

    /// 窗口是 24 小时，不是「所有历史」：更早的任务不该一直挂在列表里。
    @Test func recentTasksDropAfterTwentyFourHours() {
        let store = UsageStore()
        let now = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        store.ingest(fileURL: URL(fileURLWithPath: "/tmp/a.jsonl"), events: [
            UsageEvent(timestamp: now.addingTimeInterval(-25 * 3_600), sessionId: "old",
                       requestId: "r1", messageId: "m1", model: "claude-sonnet-4-5",
                       cwd: "/tmp/project", inputTokens: 100, outputTokens: 200,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEvent(timestamp: now.addingTimeInterval(-23 * 3_600), sessionId: "fresh",
                       requestId: "r2", messageId: "m2", model: "claude-sonnet-4-5",
                       cwd: "/tmp/project", inputTokens: 100, outputTokens: 200,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])

        #expect(store.snapshot(now: now).recentProjects.map(\.id) == ["fresh"])
    }
}
