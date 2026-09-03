import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct CodexModelUsageReaderTests {
    @Test func credentialsAndRequestUseOnlyOfficialAnalysisEndpoint() throws {
        let credentials = try CodexModelUsageReader.credentials(from: Data("""
        {
          "auth_mode": "chatgpt",
          "tokens": {"access_token": "fixture-token", "account_id": "account-1"}
        }
        """.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z"))
        let request = CodexModelUsageReader.request(
            credentials: credentials,
            now: now,
            calendar: calendar
        )
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "chatgpt.com")
        #expect(request.url?.path == "/backend-api/wham/usage/daily-token-usage-breakdown")
        #expect(query == ["start_date": "2026-08-27", "end_date": "2026-09-02", "group_by": "day"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
        #expect(CodexModelUsageReader.isOfficialURL(request.url))
        #expect(!CodexModelUsageReader.isOfficialURL(URL(string: "https://example.com/backend-api/wham/usage/daily-token-usage-breakdown")))
        #expect(!CodexModelUsageReader.isOfficialURL(URL(string: "https://chatgpt.com/backend-api/other")))
    }

    @Test func rejectsMissingOrNonChatGPTCredentials() {
        #expect(throws: CodexModelUsageError.credentialsInvalid) {
            try CodexModelUsageReader.credentials(from: Data("not json".utf8))
        }
        #expect(throws: CodexModelUsageError.credentialsInvalid) {
            try CodexModelUsageReader.credentials(from: Data("""
            {"auth_mode":"apikey","tokens":{"access_token":"token","account_id":"account"}}
            """.utf8))
        }
    }

    @Test func parsesAndZeroFillsOfficialSevenDayModelUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z"))
        let series = try CodexModelUsageReader.dailySeries(from: Data("""
        {
          "units": "percent",
          "data": [
            {"date":"2026-08-27T00:00:00Z","models":[
              {"model":"gpt-5.6-sol","credits":21.96,"speed":"standard"},
              {"model":"gpt-5.6-terra","credits":4.30,"speed":"standard"}
            ],"product_surface_usage_values":{}},
            {"date":"2026-09-01T00:00:00Z","models":[
              {"model":"gpt-5.6-sol","credits":5.42,"speed":"standard"},
              {"model":"gpt-5.6-luna","credits":0.43,"speed":"standard"}
            ],"product_surface_usage_values":{}}
          ]
        }
        """.utf8), now: now, calendar: calendar)

        #expect(series.count == 7)
        #expect(series.allSatisfy { $0.modelUsage != nil })
        #expect(series.first?.modelUsage == [
            ModelUsageSegment(model: "gpt-5.6-sol", value: 21.96),
            ModelUsageSegment(model: "gpt-5.6-terra", value: 4.30),
        ])
        #expect(series[5].modelUsage == [
            ModelUsageSegment(model: "gpt-5.6-luna", value: 0.43),
            ModelUsageSegment(model: "gpt-5.6-sol", value: 5.42),
        ])
        #expect(series.last?.modelUsage?.isEmpty == true)
        #expect(series.allSatisfy { $0.tokens == 0 })
    }

    @Test func rejectsNonPercentOrMalformedResponses() {
        #expect(throws: CodexModelUsageError.invalidResponse) {
            try CodexModelUsageReader.dailySeries(from: Data("""
            {"units":"credits","data":[]}
            """.utf8))
        }
        #expect(throws: CodexModelUsageError.invalidResponse) {
            try CodexModelUsageReader.dailySeries(from: Data("{}".utf8))
        }
    }

    @Test func officialSeriesKeepsAccountTokensAndChangesChartTitle() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let accountSeries = (0..<7).reversed().map { back in
            DailyUsagePoint(
                date: calendar.date(byAdding: .day, value: -back, to: today)!,
                tokens: back + 10
            )
        }
        let modelSeries = accountSeries.map {
            DailyUsagePoint(
                date: $0.date,
                tokens: 0,
                modelUsage: [ModelUsageSegment(model: "gpt-5.6-sol", value: 10)]
            )
        }
        let source = ProviderUsageSnapshot(provider: .codex, dailySeries: accountSeries)
        let result = CodexUsageProvider.applyingModelUsage(modelSeries, to: source)

        #expect(result.dailySeries.map(\.tokens) == accountSeries.map(\.tokens))
        #expect(result.dailySeries.allSatisfy { $0.modelUsage?.first?.model == "gpt-5.6-sol" })
        #expect(result.chartTitle == "last 7 days · plan usage")

        let invalid = CodexUsageProvider.applyingModelUsage(Array(modelSeries.prefix(6)), to: source)
        #expect(invalid == source)
    }

    @MainActor @Test func chartKeepsTopThreeModelsAndCombinesTheRest() {
        let date = Date()
        let point = DailyUsagePoint(date: date, tokens: 0, modelUsage: [
            .init(model: "gpt-5.6-sol", value: 60),
            .init(model: "gpt-5.6-terra", value: 25),
            .init(model: "gpt-5.6-luna", value: 10),
            .init(model: "future-model", value: 5),
        ])
        let keys = WeekActivityChart.visibleModelKeys(in: [point])
        let displayed = WeekActivityChart.displayedModelUsage(
            for: point,
            visibleKeys: keys,
            includesOther: WeekActivityChart.hasOtherModels(in: [point], visibleKeys: keys)
        )

        #expect(keys == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        #expect(displayed.last == ModelUsageSegment(model: WeekActivityChart.otherModelKey, value: 5))
        #expect(WeekActivityChart.englishModelName("gpt-5.6-sol", compact: true) == "Sol")
        #expect(WeekActivityChart.englishModelName("gpt-5.6-sol", compact: false) == "GPT-5.6 Sol")
    }

    @Test func refreshIntervalsMatchTheSafetyPlan() {
        #expect(CodexModelUsageReader.successTTL == 60)
        #expect(CodexModelUsageReader.failureTTL == 300)
    }

    @Test func liveOfficialModelUsageWhenExplicitlyRequested() async {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_MODEL_USAGE_INTEGRATION_TEST"] == "1" else {
            return
        }
        let series = await CodexModelUsageReader().fetch()
        #expect(series?.count == 7)
        #expect(series?.allSatisfy { $0.modelUsage != nil } == true)
    }
}
