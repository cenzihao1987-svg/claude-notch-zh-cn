import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct CodexResetForecastTests {
    @Test func decodesFreePublicStatusPayload() throws {
        let forecast = try #require(CodexResetForecastService.decodeStatus(Data("""
        {
          "data": {
            "latest_reset": null,
            "active_watch": {
              "level": "strong",
              "reset_chance_percent": 78,
              "forecast_window": "within a day",
              "observed_at": "2026-08-24T01:00:00.000Z",
              "expires_at": "2026-08-25T01:00:00.000Z",
              "text": "signal",
              "source": {"type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/1"}
            },
            "stats": {
              "total": 46,
              "last_reset_at": "2026-08-24T00:46:51.000Z",
              "days_since_last": 0.1,
              "avg_interval_days": 7.6
            }
          },
          "meta": {"api_version": "v1", "generated_at": "2026-08-24T02:15:45.485Z"}
        }
        """.utf8)))

        #expect(forecast.ageDays == 0.1)
        #expect(forecast.averageIntervalDays == 7.6)
        #expect(forecast.watchChancePercent == 78)
        #expect(forecast.watchExpiresAt != nil)
    }

    @Test func activeWatchIsShownAsSignalNotOfficialReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metric = CodexResetTile.make(
            limits: [],
            forecast: CodexResetForecast(
                ageDays: 6.2,
                averageIntervalDays: 7.6,
                watchChancePercent: 78,
                watchExpiresAt: now.addingTimeInterval(3_600)
            ),
            now: now
        )

        #expect(metric.label == "Tibo 信号")
        #expect(metric.value == "78%")
        #expect(metric.subtitle == "点击查看详情")
    }

    @Test func expiredWatchFallsBackToAverageCadence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metric = CodexResetTile.make(
            limits: [],
            forecast: CodexResetForecast(
                ageDays: 6.2,
                averageIntervalDays: 7.6,
                watchChancePercent: 78,
                watchExpiresAt: now.addingTimeInterval(-1)
            ),
            now: now
        )

        #expect(metric.label == "距上次重置")
        #expect(metric.value == "6.2 天")
        #expect(metric.subtitle == "平均 7.6 天一轮")
        #expect(CodexResetSource.websiteURL.absoluteString == "https://codex-resets.com/")
    }
}
