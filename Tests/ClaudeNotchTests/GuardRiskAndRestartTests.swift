import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardRiskAndRestartTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let system = GuardSystemEnvironment(languageCode: "zh-CN", localeIdentifier: "zh_CN", timeZoneIdentifier: "Asia/Shanghai")
    let configured = GuardSystemEnvironment(languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")

    private func snapshot(country: String = "TR", signature: GuardSignature = .local) -> GuardSnapshot {
        .init(client: .init(path: "/Applications/Claude.app", version: "test", pid: nil, launchedAt: nil, signature: signature),
              checkedAt: now, network: .init(countryCode: country, fetchedAt: now), networkInvalidated: false)
    }
    private func score(_ environment: GuardSystemEnvironment?, snapshot value: GuardSnapshot? = nil, enabled: Bool = true) -> GuardRiskAssessment {
        GuardRiskEvaluator.assess(environment: environment, snapshot: value ?? snapshot(), networkEnabled: enabled, now: now)
    }

    @Test func comparisonUsesSameNetworkAndSignatureWithoutDoubleCountingLocalSignals() {
        let before = score(system)
        let after = score(configured)
        #expect(before.total == 50)
        #expect(after.total == 10)
        #expect(before.local == 40)
        #expect(before.network == after.network)
        #expect(before.client == after.client)
    }

    @Test func chineseLanguageAloneAddsNoPoints() {
        let value = GuardSystemEnvironment(languageCode: "zh-Hans", localeIdentifier: "zh_US", timeZoneIdentifier: "America/New_York")
        #expect(score(value).local == 0)
    }

    @Test func regionOrTimezoneAloneAddsLocalPoints() {
        var value = configured
        value.localeIdentifier = "en_CN"
        #expect(score(value).local == 40)
        value = configured
        value.timeZoneIdentifier = "Asia/Urumqi"
        #expect(score(value).local == 40)
    }

    @Test func unsupportedRouteAndFailedSignatureSurviveConfigurationChange() {
        let value = snapshot(country: "CN", signature: .invalid(code: -1))
        #expect(score(system, snapshot: value).total == 100)
        #expect(score(configured, snapshot: value).total == 60)
        #expect(score(configured, snapshot: snapshot(signature: .valid(publisher: "TEST"))).total == 0)
    }

    @Test func missingStaleDisabledAndInvalidInputsHaveNoTotal() {
        #expect(score(nil).total == nil)
        var value = configured
        value.localeIdentifier = "en_XX"
        #expect(score(value).total == nil)
        value = configured
        value.timeZoneIdentifier = "Made/Up"
        #expect(score(value).total == nil)
        #expect(score(configured, enabled: false).total == nil)
        #expect(score(configured, snapshot: snapshot(signature: .unavailable)).total == nil)
        #expect(score(configured, snapshot: snapshot(country: "XX")).total == nil)
        var observation = snapshot()
        observation.networkInvalidated = true
        #expect(score(configured, snapshot: observation).total == nil)
        observation = snapshot()
        observation.network = .init(countryCode: "TR", fetchedAt: now.addingTimeInterval(-901))
        #expect(score(configured, snapshot: observation).total == nil)
        observation.client = nil
        #expect(score(configured, snapshot: observation).total == nil)
    }

    @Test func riskLevelBoundaries() {
        for (value, title) in [(0, "风险较低"), (19, "风险较低"), (20, "风险中等"), (49, "风险中等"),
                               (50, "风险较高"), (79, "风险较高"), (80, "风险很高"), (100, "风险很高")] {
            #expect(GuardRiskAssessment(local: value, network: 0, client: 0).level(.chinese) == title)
        }
        #expect(GuardRiskAssessment(local: nil, network: 0, client: 0).level(.chinese) == "待检测")
    }

    @MainActor @Test func restartWaitsUntilEveryInstanceHasExited() async throws {
        var events: [String] = []
        var waits = 0
        try await GuardRestartCoordinator.run(requestExit: { events.append("quit"); return true },
            isRunning: { waits < 2 }, launch: { events.append("launch") },
            wait: { events.append("wait"); waits += 1 })
        #expect(events == ["quit", "wait", "wait", "launch"])
    }

    @MainActor @Test func refusedQuitNeverLaunchesAnotherInstance() async {
        var launched = false
        do {
            try await GuardRestartCoordinator.run(requestExit: { false }, isRunning: { true },
                launch: { launched = true }, wait: { Issue.record("Must not wait after refusal") })
            Issue.record("Expected quit refusal")
        } catch { #expect(error as? GuardRestartError == .refused) }
        #expect(!launched)
    }

    @MainActor @Test func timeoutStopsAfterThirtyHalfSecondPolls() async {
        var waits = 0
        var launched = false
        do {
            try await GuardRestartCoordinator.run(requestExit: { true }, isRunning: { true },
                launch: { launched = true }, wait: { waits += 1 })
            Issue.record("Expected timeout")
        } catch { #expect(error as? GuardRestartError == .timedOut) }
        #expect(waits == 30)
        #expect(!launched)
    }

    @MainActor @Test func exitAtFinalPollStillAllowsLaunch() async throws {
        var waits = 0
        var launched = false
        try await GuardRestartCoordinator.run(requestExit: { true }, isRunning: { waits < 30 },
            launch: { launched = true }, wait: { waits += 1 })
        #expect(launched)
        #expect(waits == 30)
    }

    @MainActor @Test func cancelledWaitDoesNotLaunch() async {
        var launched = false
        do {
            try await GuardRestartCoordinator.run(requestExit: { true }, isRunning: { true },
                launch: { launched = true }, wait: { throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(!launched)
    }

    @MainActor @Test func alreadyStoppedNeedsNoQuitRequest() async throws {
        var launched = false
        try await GuardRestartCoordinator.run(requestExit: { Issue.record("Must not ask a stopped process to quit"); return false },
            isRunning: { false }, launch: { launched = true })
        #expect(launched)
    }

    #if DEBUG
    @MainActor @Test func manualRecheckPublishesLoadingCoalescesDuplicatesAndPreservesTheFixture() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.Recheck.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.loadDesignPreview(running: true)
        let profile = service.profile
        let snapshotDate = service.snapshot.checkedAt
        let check = Task { await service.recheck() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !service.isRechecking && clock.now < deadline { await Task.yield() }
        #expect(service.isRechecking)
        // A second action returns without queuing another check or ending this one.
        await service.recheck()
        #expect(service.isRechecking)
        await check.value
        #expect(!service.isRechecking)
        #expect(service.profile == profile)
        #expect(service.snapshot.checkedAt == snapshotDate)
        #expect(defaults.data(forKey: EnvironmentGuardService.profileKey) == nil)
    }

    @MainActor @Test func stoppingAnOldRecheckCannotClearANewerLoadingState() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.RecheckCancel.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.loadDesignPreview(running: true)
        let old = Task { await service.recheck() }
        let clock = ContinuousClock()
        let firstDeadline = clock.now.advanced(by: .seconds(1))
        while !service.isRechecking && clock.now < firstDeadline { await Task.yield() }
        #expect(service.isRechecking)
        service.stop()
        #expect(!service.isRechecking)
        let next = Task { await service.recheck() }
        let nextDeadline = clock.now.advanced(by: .seconds(1))
        while !service.isRechecking && clock.now < nextDeadline { await Task.yield() }
        #expect(service.isRechecking)
        old.cancel()
        await old.value
        #expect(service.isRechecking)
        await next.value
        #expect(!service.isRechecking)
    }

    @MainActor @Test func runningFixtureCannotRestartOrLaunchRealClaude() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.RunningPreview.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.loadDesignPreview(running: true)
        #expect(service.snapshot.client?.pid == Int32.max)
        var value = service.profile
        value.enabled = false
        service.updateProfile(value)
        #expect(await service.restartWithoutProfile() == false)
        #expect(await service.launchClaude() == false)
        value.enabled = true
        service.updateProfile(value)
        #expect(await service.restartWithProfile() == false)
        #expect(defaults.data(forKey: EnvironmentGuardService.profileKey) == nil)
    }

    @MainActor @Test func previewScoresAndRemindersMatchApprovedImageWithoutPersisting() throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.RiskPreview.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.loadDesignPreview()
        #expect(service.currentRisk.total == 50)
        #expect(service.configuredRisk.total == 10)
        #expect(service.verificationReminderCount == 2)
        #expect(service.verificationUnknownCount == 1)
        var profile = service.profile
        profile.enabled = false
        service.updateProfile(profile)
        #expect(service.configuredRisk.total == 10)
        #expect(defaults.data(forKey: EnvironmentGuardService.profileKey) == nil)
    }
    #endif
}
