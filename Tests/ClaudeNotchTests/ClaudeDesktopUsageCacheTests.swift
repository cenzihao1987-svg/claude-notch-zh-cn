import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Claude Desktop usage cache")
struct ClaudeDesktopUsageCacheTests {
    @Test func liveDesktopCacheWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_RUN_CACHE_INTEGRATION_TEST"] == "1"
        else { return }

        let result = try #require(await ClaudeDesktopUsageCache().latest())
        let age = Date().timeIntervalSince(result.fetchedAt)
        print("Claude Desktop usage cache age: \(Int(age))s")
        #expect(result.sessionPct != nil || result.weeklyPct != nil)
    }

    @Test func parsesOfficialUsageResponse() throws {
        let data = Data(#"""
        {
          "five_hour":{"utilization":92.0,"resets_at":"2026-08-17T11:59:59.884933+00:00"},
          "seven_day":{"utilization":21.0,"resets_at":"2026-08-21T23:59:59.884960+00:00"}
        }
        """#.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_786_958_979)

        let result = try #require(ClaudeDesktopUsageCache.parseUsageJSON(data, fetchedAt: fetchedAt))

        #expect(result.sessionPct == 0.92)
        #expect(result.weeklyPct == 0.21)
        #expect(result.fetchedAt == fetchedAt)
        #expect(result.sessionResetsAt != nil)
        #expect(result.weeklyResetsAt != nil)
    }

    @Test func rejectsDataWithoutOfficialLimitWindows() {
        let data = Data(#"{"local_estimate":57}"#.utf8)
        #expect(ClaudeDesktopUsageCache.parseUsageJSON(data, fetchedAt: Date()) == nil)
    }

    @Test func expiredSessionWindowIsNotFresh() {
        let usage = ClaudeDesktopCachedUsage(
            sessionPct: 0.92,
            sessionResetsAt: Date(timeIntervalSince1970: 100),
            weeklyPct: 0.21,
            weeklyResetsAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 90)
        )
        #expect(!usage.isFresh(now: Date(timeIntervalSince1970: 101), after: 300))
    }

    @Test func cacheOlderThanDisplayFreshnessIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = ClaudeDesktopCachedUsage(
            sessionPct: 0.92,
            sessionResetsAt: Date(timeIntervalSince1970: 2_000),
            weeklyPct: 0.21,
            weeklyResetsAt: nil,
            fetchedAt: now.addingTimeInterval(-AppModel.claudeUsageFreshAfter - 1)
        )

        #expect(!usage.isFresh(now: now, after: AppModel.claudeUsageFreshAfter))
    }

    @Test func recognizesProCapability() {
        let data = Data(#"{"capabilities":["claude_pro","chat"]}"#.utf8)
        #expect(ClaudeDesktopUsageCache.parseSubscriptionJSON(data) == .pro)
    }

    @Test func recognizesEveryMaxCapabilityVariant() {
        for capability in ["claude_max", "claude_max_5x", "claude_max_20x"] {
            let data = Data("{\"capabilities\":[\"\(capability)\",\"claude_pro\"]}".utf8)
            #expect(ClaudeDesktopUsageCache.parseSubscriptionJSON(data) == .max)
        }
    }

    @Test func leavesUnknownPlansUnclassified() {
        let data = Data(#"{"capabilities":["chat"]}"#.utf8)
        #expect(ClaudeDesktopUsageCache.parseSubscriptionJSON(data) == nil)
    }

    @Test func organizationTypeFromClaudeCodeConfigMapsToTier() {
        #expect(ClaudeSubscriptionTier(organizationType: "claude_pro") == .pro)
        #expect(ClaudeSubscriptionTier(organizationType: "claude_max") == .max)
        #expect(ClaudeSubscriptionTier(organizationType: "claude_max_20x") == .max)
        #expect(ClaudeSubscriptionTier(organizationType: "claude_team") == nil)
        #expect(ClaudeSubscriptionTier(organizationType: "") == nil)
    }

    /// Cold start must still find an older usage response behind newer asset entries.
    @Test func coldLookupFindsUsageBeyondNewestAssetCandidates() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let usageBody = #"{"five_hour":{"utilization":40.0},"seven_day":{"utilization":10.0}}"#

        for usageModified in [base.addingTimeInterval(-100), base.addingTimeInterval(1_000)] {
            let (home, cache) = try makeCacheHome()
            defer { try? FileManager.default.removeItem(at: home) }
            for i in 0..<ClaudeDesktopUsageCache.maxCandidates {
                try writeEntry(cache, index: i, key: "1/0/https://claude.ai/api/other/\(i)", body: "{}",
                               modified: base.addingTimeInterval(Double(i)))
            }
            try writeEntry(cache, index: 9_999, key: "1/0/https://claude.ai/api/organizations/org/usage",
                           body: usageBody, modified: usageModified)

            let usage = await ClaudeDesktopUsageCache(home: home).latest()
            #expect(usage?.sessionPct == 0.4)
        }
    }

    @Test func queryVariantsRefreshAndScansAreThrottled() async throws {
        let (home, cache) = try makeCacheHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeEntry(cache, index: 1, key: "1/0/https://claude.ai/api/organizations/org/usage",
                       body: #"{"five_hour":{"utilization":40.0}}"#, modified: now)
        let reader = ClaudeDesktopUsageCache(home: home)
        #expect(await reader.latest(now: now)?.sessionPct == 0.4)
        try writeEntry(cache, index: 2, key: "1/0/https://claude.ai/api/organizations/org/usage?skip_spend=1",
                       body: #"{"five_hour":{"utilization":55.0}}"#, modified: now.addingTimeInterval(1))
        #expect(await reader.latest(now: now.addingTimeInterval(29))?.sessionPct == 0.4)
        #expect(await reader.latest(now: now.addingTimeInterval(30))?.sessionPct == 0.55)
        try writeEntry(cache, index: 3, key: "1/0/https://claude.ai/api/organizations/org/usage?cedar_ember=1",
                       body: #"{"five_hour":{"utilization":60.0}}"#, modified: now.addingTimeInterval(31))
        #expect(await reader.latest(now: now.addingTimeInterval(32), force: true)?.sessionPct == 0.6)
    }

    @Test func unreadableNewestEntryDoesNotHideOlderValidResponse() async throws {
        let (home, cache) = try makeCacheHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeEntry(cache, index: 1, key: "1/0/https://claude.ai/api/organizations/org/usage?skip_spend=1",
                       body: #"{"five_hour":{"utilization":32.0}}"#, modified: now)
        try writeEntry(cache, index: 2, key: "1/0/https://claude.ai/api/organizations/org/usage",
                       body: "{", modified: now.addingTimeInterval(1))
        let reader = ClaudeDesktopUsageCache(home: home)
        #expect(await reader.latest()?.sessionPct == 0.32)
        for file in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        #expect(await reader.latest(now: now.addingTimeInterval(40))?.sessionPct == 0.32)
    }

    @Test func subscriptionLookupRunsAtMostEveryTenMinutes() async throws {
        let (home, cache) = try makeCacheHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = ClaudeDesktopUsageCache(home: home)
        let start = Date()

        #expect(await reader.subscriptionTier(now: start) == nil)
        try writeEntry(cache, index: 1, key: "1/0/https://claude.ai/api/organizations/org",
                       body: #"{"capabilities":["claude_max"]}"#, modified: start)
        #expect(await reader.subscriptionTier(now: start.addingTimeInterval(60)) == nil)
        let later = start.addingTimeInterval(ClaudeDesktopUsageCache.subscriptionCheckInterval)
        #expect(await reader.subscriptionTier(now: later) == .max)
    }

    private func makeCacheHome() throws -> (home: URL, cache: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = home.appendingPathComponent(
            "Library/Application Support/Claude/Cache/Cache_Data", isDirectory: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return (home, cache)
    }

    /// Chromium Simple Cache 的最小形态：第 12 字节起是 key 长度，第 24 字节起是 key，随后是正文。
    private func writeEntry(_ directory: URL, index: Int, key: String, body: String,
                            modified: Date) throws {
        var data = Data(count: 24)
        let keyData = Data(key.utf8)
        withUnsafeBytes(of: UInt32(keyData.count).littleEndian) { data.replaceSubrange(12..<16, with: $0) }
        data.append(keyData)
        data.append(Data(body.utf8))
        let url = directory.appendingPathComponent(String(format: "%016x_0", index))
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
