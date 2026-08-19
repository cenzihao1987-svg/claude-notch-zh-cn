import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Claude Desktop usage cache")
struct ClaudeDesktopUsageCacheTests {
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
}
