import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct CodexSnapshotMapperTests {
    @MainActor @Test func codexDashboardKeepsOnlyTwoByTwoSummaryTiles() {
        let snapshot = ProviderUsageSnapshot(
            provider: .codex,
            limits: [
                .init(id: "codex-primary", label: "Codex · 5-Hour", usedFraction: 0.1, resetsAt: nil),
                .init(id: "codex-secondary", label: "Codex · 7-Day", usedFraction: 0.2, resetsAt: nil),
                .init(id: "gpt-reserve-secondary", label: "GPT reserve · 7-Day", usedFraction: 0.3, resetsAt: nil),
            ],
            stats: [
                .init(id: "tokens-yesterday", label: "yesterday", value: "12.2M", subtitle: nil),
                .init(id: "credits", label: "credits", value: "500", subtitle: nil),
                .init(id: "reset", label: "reset", value: "0.8 days", subtitle: nil),
            ]
        )

        #expect(IslandView.singlePageLimits(for: snapshot).map(\.id) == [
            "codex-primary", "codex-secondary",
        ])
        #expect(IslandView.singlePageStats(for: snapshot).map(\.id) == ["credits", "reset"])
    }

    @Test func liveAppServerExchangeWhenRequested() async {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_INTEGRATION_TEST"] == "1" else {
            return
        }

        let snapshot = await CodexUsageProvider().fetch()

        #expect(snapshot.source == "Codex app-server")
        #expect(!snapshot.limits.isEmpty)
        #expect(snapshot.lifetimeTokens != nil)
        if ProcessInfo.processInfo.environment["CODEX_NOTCH_EXPECT_THREAD_USAGE"] == "1",
           !snapshot.sessions.isEmpty {
            #expect(snapshot.sessions.contains { ($0.tokens ?? 0) > 0 })
        }
    }

    @Test func mapsOfficialAppServerPayloads() throws {
        let account = try decode(CodexAccountResponse.self, json: """
        {
          "account": {"type": "chatgpt", "email": "user@example.com", "planType": "plus"},
          "requiresOpenaiAuth": true
        }
        """)
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "credits": {"balance": "12.50", "hasCredits": true, "unlimited": false},
            "limitId": "codex",
            "limitName": "Codex",
            "planType": "plus",
            "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1784556000},
            "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1785160800}
          },
          "rateLimitsByLimitId": null
        }
        """)
        let usage = try decode(CodexAccountUsageResponse.self, json: """
        {
          "summary": {"lifetimeTokens": 1234567},
          "dailyUsageBuckets": [{"startDate": "2026-07-20", "tokens": 45678}]
        }
        """)
        let threads = try decode(CodexThreadListResponse.self, json: """
        {
          "data": [{
            "id": "thread-1",
            "cwd": "/Users/example/Projects/notch",
            "name": "Provider abstraction",
            "preview": "Implement provider support",
            "updatedAt": 1784552400
          }]
        }
        """)
        let threadUsage = try decode(CodexThreadUsageResponse.self, json: """
        {
          "summary": {},
          "threadUsage": {
            "threadId": "thread-1",
            "estimatedUsageCreditsMicros": 123,
            "estimatedUsageUsdMicros": 12,
            "groups": [
              {
                "model": "gpt-5.6",
                "totalTokens": 120000,
                "inputTokens": 118000,
                "cachedInputTokens": 100000,
                "outputTokens": 2000,
                "estimatedUsageCreditsMicros": 100
              },
              {
                "model": "gpt-5.5",
                "totalTokens": 6020,
                "inputTokens": 6000,
                "cachedInputTokens": 5000,
                "outputTokens": 20,
                "estimatedUsageCreditsMicros": 23
              }
            ]
          }
        }
        """)
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 12
        )))

        let snapshot = CodexSnapshotMapper.make(
            account: account,
            rateLimits: rateLimits,
            usage: usage,
            threads: threads,
            threadTokens: ["thread-1": try #require(threadUsage.threadUsage?.totalTokens)],
            now: now
        )

        #expect(snapshot.provider == .codex)
        #expect(snapshot.limits.map(\.label) == ["5-Hour", "7-Day"])
        #expect(snapshot.limits.map(\.usedFraction) == [0.42, 0.70])
        #expect(snapshot.todayTokens == 45_678)
        #expect(snapshot.lifetimeTokens == 1_234_567)
        #expect(snapshot.planName == "Codex Plus")
        #expect(snapshot.stats.first(where: { $0.id == "credits" })?.value == "12.50")
        #expect(snapshot.sessions.first?.name == "Provider abstraction")
        #expect(snapshot.sessions.first?.tokens == 126_020)
        #expect(snapshot.statusMessage == nil)
    }

    @Test func keepsTopLevelSnapshotAndAppendsDistinctBuckets() throws {
        // Mirrors upstream app_server_rate_limit_snapshots: the top-level snapshot survives even
        // when rateLimitsByLimitId repeats it, and distinct buckets are appended after it. Also
        // exercises the ±5% duration tolerance (299 minutes must still label as 5-Hour).
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1784556000},
            "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1785160800}
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": "Codex",
              "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1784556000},
              "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1785160800}
            },
            "codex-mini": {
              "limitId": "codex-mini",
              "limitName": "Codex Mini",
              "primary": {"usedPercent": 5, "windowDurationMins": 299, "resetsAt": 1784556000}
            }
          }
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: rateLimits, usage: nil, threads: nil, now: Date()
        )

        #expect(snapshot.limits.map(\.label) ==
            ["Codex · 5-Hour", "Codex · 7-Day", "Codex Mini · 5-Hour"])
        #expect(snapshot.limits.map(\.usedFraction) == [0.42, 0.70, 0.05])
    }

    @Test func ordersShortCodexWindowBeforeWeeklyWhenServerSwapsPrimaryAndSecondary() throws {
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1785160800},
            "secondary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1784556000}
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: rateLimits, usage: nil, threads: nil, now: Date()
        )

        #expect(snapshot.limits.map(\.label) == ["5-Hour", "7-Day"])
        #expect(snapshot.limits.map(\.usedFraction) == [0.42, 0.70])
        #expect(snapshot.primaryUsage == 0.42)
    }

    @Test func fillsSpareTilesWithLifetimeStatsAndFlagsSpendControl() throws {
        // Shaped like a real account with one 30-day window, no secondary, and a lagging daily
        // feed — the case that otherwise renders a sparse four-tile page.
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "credits": {"balance": null, "hasCredits": false, "unlimited": false},
            "limitId": "codex",
            "limitName": null,
            "planType": "free",
            "primary": {"usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 1787222684},
            "secondary": null,
            "spendControlReached": true
          },
          "rateLimitsByLimitId": null
        }
        """)
        let usage = try decode(CodexAccountUsageResponse.self, json: """
        {
          "summary": {
            "lifetimeTokens": 1914879665,
            "peakDailyTokens": 501548755,
            "longestRunningTurnSec": 54891,
            "currentStreakDays": 0,
            "longestStreakDays": 9
          },
          "dailyUsageBuckets": []
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: rateLimits, usage: usage, threads: nil, now: Date()
        )

        #expect(snapshot.limits.map(\.label) == ["Monthly"])
        #expect(snapshot.stats.first(where: { $0.id == "peak-day" })?.value == Fmt.tokens(501_548_755))
        #expect(snapshot.stats.first(where: { $0.id == "longest-task" })?.value == "15h 14m")
        #expect(snapshot.statusMessage == "Spend limit reached")
        let ids = snapshot.stats.map(\.id)
        #expect(!ids.contains("credits"))   // zero balance: no dead-weight credits tile
        // Spare stats stay behind the important ones so a six-slot grid drops them first.
        #expect(ids.firstIndex(of: "peak-day")! > ids.firstIndex(of: "reset")!)
    }

    @Test func buildsZeroFilledWeekSeriesEndingToday() throws {
        let calendar = Calendar.current
        let now = Date()
        func day(_ back: Int) -> String {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: calendar.date(byAdding: .day, value: -back, to: now)!)
        }
        let usage = try decode(CodexAccountUsageResponse.self, json: """
        {
          "summary": {"lifetimeTokens": 100},
          "dailyUsageBuckets": [
            {"startDate": "\(day(0))", "tokens": 5},
            {"startDate": "\(day(1))", "tokens": 7},
            {"startDate": "\(day(2))", "tokens": 11},
            {"startDate": "\(day(30))", "tokens": 999}
          ]
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: nil, usage: usage, threads: nil, now: now
        )

        #expect(snapshot.dailySeries.count == 7)
        #expect(snapshot.dailySeries.map(\.tokens) == [0, 0, 0, 0, 11, 7, 5])
        #expect(Calendar.current.isDateInToday(snapshot.dailySeries.last!.date))
        // Identities are normalized to startOfDay so bars keep the same identity across
        // refreshes at different times of day.
        #expect(snapshot.dailySeries.last!.date == Calendar.current.startOfDay(for: now))
        let later = CodexSnapshotMapper.make(
            account: nil, rateLimits: nil, usage: usage, threads: nil,
            now: now.addingTimeInterval(3600)
        )
        #expect(later.dailySeries.map(\.date) == snapshot.dailySeries.map(\.date)
            || Calendar.current.isDate(now.addingTimeInterval(3600), inSameDayAs: now) == false)
        #expect(snapshot.weekTokens == 23)
        #expect(snapshot.stats.first(where: { $0.id == "tokens-yesterday" })?.value == "7")
    }

    @Test func suppressesEmptyCreditsTile() throws {
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "credits": {"balance": "0", "hasCredits": false, "unlimited": false},
            "limitId": "codex",
            "primary": {"usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 1785160800}
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: rateLimits, usage: nil, threads: nil, now: Date()
        )

        #expect(!snapshot.stats.contains { $0.id == "credits" })
        #expect(snapshot.dailySeries.isEmpty)   // no usage feed: UI falls back to the tile grid
    }

    @Test func keepsZeroYesterdayTokenTileToFillSummaryGrid() throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let usage = try decode(CodexAccountUsageResponse.self, json: """
        {
          "summary": {"lifetimeTokens": 100},
          "dailyUsageBuckets": [
            {"startDate": "\(formatter.string(from: twoDaysAgo))", "tokens": 100}
          ]
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil, rateLimits: nil, usage: usage, threads: nil, now: now
        )

        #expect(snapshot.stats.first(where: { $0.id == "tokens-yesterday" })?.value == "0")
    }

    @Test func explainsMissingUsageForAPIKeyAuth() throws {
        let account = try decode(CodexAccountResponse.self, json: """
        {
          "account": {"type": "apiKey"},
          "requiresOpenaiAuth": false
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: account,
            rateLimits: nil,
            usage: nil,
            threads: nil,
            errors: [4: "Usage is unavailable"],
            now: Date()
        )

        #expect(snapshot.statusMessage == "Account usage requires ChatGPT sign-in")
        #expect(snapshot.todayCost == nil)
        #expect(snapshot.lifetimeCost == nil)
    }

    @Test func neverDisplaysRawThreadPreview() throws {
        let threads = try decode(CodexThreadListResponse.self, json: """
        {
          "data": [{
            "id": "thread-private",
            "cwd": "/Users/example/Projects/notch",
            "name": null,
            "preview": "Confidential prompt content",
            "updatedAt": 1784552400
          }]
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil,
            rateLimits: nil,
            usage: nil,
            threads: threads,
            now: Date()
        )

        #expect(snapshot.sessions.first?.name == "notch")
        #expect(snapshot.sessions.first?.name != "Confidential prompt content")
        #expect(snapshot.sessions.first?.tokens == nil)
    }

    @Test func readsLatestCumulativeTokenCountWithoutUsingPromptContent() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200}}}}
        {"type":"response_item","payload":{"type":"message","content":"private prompt"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":3456}}}}
        """.utf8)

        #expect(CodexThreadTokenReader.totalTokens(in: data) == 3_456)
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
