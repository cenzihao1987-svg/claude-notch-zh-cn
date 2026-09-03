import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct DeepSeekUsageProviderTests {
    @Test func selectsOnlyActiveOfficialDeepSeekConfiguration() throws {
        let key = try DeepSeekUsageProvider.apiKey(from: Data("""
        {
          "responsesUpstream": [
            {"baseUrl": "https://other.example", "apiKeys": ["ignored"], "serviceType": "openai", "status": "active"},
            {"baseUrl": "https://api.deepseek.com/v1", "apiKeys": [""], "serviceType": "openai", "status": "active"},
            {"baseUrl": "https://api.deepseek.com", "apiKeys": ["fixture-key"], "serviceType": "openai", "status": "active"}
          ]
        }
        """.utf8))

        #expect(key == "fixture-key")
    }

    @Test func rejectsNonOfficialOrInactiveConfigurations() {
        let invalid = Data("""
        {
          "responsesUpstream": [
            {"baseUrl": "http://api.deepseek.com", "apiKeys": ["fixture-key"], "serviceType": "openai", "status": "active"},
            {"baseUrl": "https://api.deepseek.com", "apiKeys": ["fixture-key"], "serviceType": "anthropic", "status": "active"},
            {"baseUrl": "https://api.deepseek.com", "apiKeys": ["fixture-key"], "serviceType": "openai", "status": "disabled"}
          ]
        }
        """.utf8)

        #expect(throws: DeepSeekUsageError.configurationNotFound) {
            try DeepSeekUsageProvider.apiKey(from: invalid)
        }
    }

    @Test func handlesMalformedAndMissingConfiguration() {
        #expect(throws: DeepSeekUsageError.configurationInvalid) {
            try DeepSeekUsageProvider.apiKey(from: Data("not json".utf8))
        }
        #expect(throws: DeepSeekUsageError.configurationMissing) {
            try DeepSeekUsageProvider.apiKey(from: URL(fileURLWithPath: "/tmp/claude-notch-no-deepseek-config.json"))
        }
    }

    @Test func requestTargetsOnlyTheOfficialBalanceEndpoint() {
        let request = DeepSeekUsageProvider.balanceRequest(apiKey: "fixture-key")
        #expect(request.url == DeepSeekUsageProvider.balanceURL)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "api.deepseek.com")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @MainActor @Test func mapsCNYUSDAndAvailabilityWithoutInventingPercentages() {
        let response = DeepSeekBalanceResponse(
            isAvailable: true,
            balanceInfos: [
                .init(currency: "USD", totalBalance: "2.5", grantedBalance: "0", toppedUpBalance: "2.5"),
                .init(currency: "CNY", totalBalance: "110", grantedBalance: "10", toppedUpBalance: "100"),
            ]
        )
        let snapshot = DeepSeekUsageProvider.snapshot(from: response, fetchedAt: Date(timeIntervalSince1970: 1))

        #expect(snapshot.provider == .deepseek)
        #expect(snapshot.primaryUsage == nil)
        #expect(snapshot.headlineValue == "¥110.00")
        #expect(snapshot.stats.first(where: { $0.id == "deepseek-total-balance" })?.value == "$2.50 · ¥110.00")
        #expect(snapshot.stats.first(where: { $0.id == "deepseek-api-status" })?.value == "available")
        #expect(IslandView.singlePageStats(for: snapshot).count == 4)
    }

    @Test func zeroBalanceAndUnavailableStatusArePreserved() {
        let snapshot = DeepSeekUsageProvider.snapshot(from: .init(
            isAvailable: false,
            balanceInfos: [.init(currency: "CNY", totalBalance: "0", grantedBalance: "0", toppedUpBalance: "0")]
        ), fetchedAt: Date())

        #expect(snapshot.headlineValue == "¥0.00")
        #expect(snapshot.stats.last?.value == "unavailable")
    }

    @Test func providerOrderPlacesWorkBuddyBeforeDeepSeek() {
        #expect(UsageProviderID.allCases == [.claude, .codex, .workbuddy, .deepseek])
    }

    @Test func liveOfficialBalanceWhenExplicitlyRequested() async {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_DEEPSEEK_INTEGRATION_TEST"] == "1" else {
            return
        }
        let result = await DeepSeekUsageProvider().fetch()
        switch result {
        case let .success(snapshot):
            #expect(snapshot.provider == .deepseek)
            #expect(snapshot.headlineValue != nil)
            #expect(snapshot.stats.count == 4)
        case let .failure(error):
            Issue.record("DeepSeek integration failed: \(error.message)")
        }
    }
}
