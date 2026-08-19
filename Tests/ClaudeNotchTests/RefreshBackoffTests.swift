import Testing
import Foundation
@testable import ClaudeNotch

/// 2026-08-17 的回归测试：15 秒刷新 + 失败不退避，把账号打到了 api.anthropic.com 的 429。
/// 死锁链条是「取数失败 → 不记录尝试时刻 → 下一个 tick 照样发 → 又失败」，
/// 而展开态那条 `if isExpanded { return true }` 让用户展开着刘海就能无限重试。
/// 这里钉住的是修复后的不变量：失败必须让间隔变长，而且展开态不能绕过它。
@MainActor
@Suite struct RefreshBackoffTests {

    @Test func desktopOnlyFallbackRejectsOtherApps() {
        #expect(ClaudeAPIService.isAllowedFallbackSource("Claude Desktop"))
        #expect(!ClaudeAPIService.isAllowedFallbackSource("Chrome"))
        #expect(!ClaudeAPIService.isAllowedFallbackSource("Microsoft Edge"))
        #expect(!ClaudeAPIService.isAllowedFallbackSource("Claude Code"))
    }

    @Test func collapsedBaselineIsNinetySeconds() {
        let model = AppModel()
        model.isExpanded = false
        #expect(model.claudeMinGap == 90)
    }

    @Test func expandedBaselineIsThirtySeconds() {
        let model = AppModel()
        model.isExpanded = true
        #expect(model.claudeMinGap == 30)
    }

    /// 每多失败一次，间隔翻倍：90 → 180 → 360 → 720。
    @Test func eachFailureDoublesTheGap() {
        let model = AppModel()
        model.isExpanded = false
        for (failures, expected) in [(1, 180.0), (2, 360.0), (3, 720.0)] {
            model.claudeFailures = failures
            #expect(model.claudeMinGap == expected)
        }
    }

    /// 翻倍不能无上限，否则失败一整天后间隔会长到永远不再重试。
    @Test func backoffStopsAtFifteenMinutes() {
        let model = AppModel()
        model.claudeFailures = 4
        #expect(model.claudeMinGap == 900)
        model.claudeFailures = 20
        #expect(model.claudeMinGap == 900)   // 2^20 不该溢出成别的数
    }

    /// 事故的要害：展开态曾经无条件放行。限流中展开刘海必须照样退避。
    @Test func expandedStateCannotBypassBackoff() {
        let model = AppModel()
        model.isExpanded = true
        model.claudeFailures = 1
        #expect(model.claudeMinGap == 180)
        #expect(model.claudeMinGap > 30)
    }

    /// 一次成功要把退避清零，否则偶发失败会永久拖慢正常刷新。
    @Test func successResetsTheStreak() {
        let model = AppModel()
        model.isExpanded = false
        model.claudeFailures = 3
        #expect(model.claudeMinGap == 720)
        model.claudeFailures = 0
        #expect(model.claudeMinGap == 90)
    }
}
