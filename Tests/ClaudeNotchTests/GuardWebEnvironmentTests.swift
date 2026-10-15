import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardWebEnvironmentTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = String(repeating: "a", count: 32)
    let profile = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
    var client: GuardClient { .init(path: "/Applications/Claude.app", version: "test", pid: 123, launchedAt: now.addingTimeInterval(-10), signature: .local, runningInstanceCount: 1) }
    var receipt: LaunchReceipt { .init(pid: 123, launchedAt: now.addingTimeInterval(-10), appPath: "/Applications/Claude.app", profile: profile, webSession: session) }
    var frame: GuardWebFrame { .init(context: "claude.ai", language: "en-US", languages: ["en-US", "en"], locale: "en-US", timeZone: "America/Los_Angeles") }
    func report(frames: [GuardWebFrame], candidates: Int? = nil, failed: Int = 0) -> GuardWebReport {
        .init(protocol: 1, session: session, pid: 123, capturedAt: now.timeIntervalSince1970 * 1000,
              candidateCount: candidates ?? frames.count, failedCount: failed, frames: frames)
    }
    func finding(_ report: GuardWebReport, pending: Bool = false) -> GuardFinding {
        GuardWebEvaluator.finding(profile: profile, state: .observed(report), launchPending: pending)
    }
    func decode(_ value: GuardWebReport) throws -> GuardWebState {
        GuardWebEnvironmentReader.decode(try JSONEncoder().encode(value), client: client, receipt: receipt, now: now)
    }
    func unavailable(_ state: GuardWebState) -> Bool { if case .unavailable = state { return true }; return false }

    @Test func actualMatchingValuesPassWithLocaleNormalizationAndTimezoneAliases() throws {
        #expect(GuardWebEvaluator.languageMatches("en_US", "en-US"))
        #expect(GuardWebEvaluator.languageMatches("zh-CN", "zh-Hans"))
        #expect(!GuardWebEvaluator.languageMatches("zh-TW", "zh-Hans"))
        #expect(GuardWebEvaluator.localeMatches("en-US", "en_US"))
        #expect(GuardWebEvaluator.localeMatches("en-TR", "en_TR"))
        #expect(!GuardWebEvaluator.localeMatches("en-US", "en_TR"))
        #expect(GuardWebEvaluator.timezoneMatches("US/Pacific", "America/Los_Angeles"))
        #expect(!GuardWebEvaluator.localeMatches("en-GB", "en_US"))
        #expect(!GuardWebEvaluator.timezoneMatches("America/New_York", "America/Los_Angeles"))
        let observation = report(frames: [frame])
        #expect(!unavailable(try decode(observation)))
        #expect(finding(observation).state == .passed)
        #expect(finding(observation).actionID == nil)
    }

    @Test func pageDifferencesAddOneCauseAndPreserveActualValues() {
        let value = GuardWebFrame(context: "Claude Desktop", language: "zh-CN", languages: ["zh-CN"], locale: "zh-CN", timeZone: "Asia/Shanghai")
        let result = finding(report(frames: [value]))
        #expect(result.state == .attention)
        #expect(result.actionID == "chromium")
        #expect(result.detail.chinese.contains("Asia/Shanghai"))
        #expect(result.detail.chinese.contains("America/Los_Angeles"))
        #expect(GuardWebEvaluator.mismatches(value, profile: profile).count == 3)
        #expect(finding(report(frames: [value]), pending: true).actionID == "launch")
    }

    @Test func oneMismatchingPagePreventsAnOverallPass() {
        let wrong = GuardWebFrame(context: "claude.ai", language: "en-US", languages: ["en-US"], locale: "en-US", timeZone: "Asia/Shanghai")
        #expect(finding(report(frames: [frame, wrong])).state == .attention)
    }

    @Test func secondaryLanguageIsVisibleButNotAnUnconfiguredRequirement() {
        let value = GuardWebFrame(context: "claude.ai", language: "en-US", languages: ["en-US", "zh-CN"], locale: "en-US", timeZone: "America/Los_Angeles")
        #expect(finding(report(frames: [value])).state == .passed)
        let wrongPrimary = GuardWebFrame(context: "claude.ai", language: "en-US", languages: ["zh-CN", "en-US"], locale: "en-US", timeZone: "America/Los_Angeles")
        #expect(finding(report(frames: [wrongPrimary])).state == .attention)
    }

    @Test func partialAndEmptySamplesCannotPass() throws {
        let partial = report(frames: [frame], candidates: 2, failed: 1)
        #expect(!unavailable(try decode(partial)))
        #expect(finding(partial).state == .unknown)
        #expect(finding(report(frames: [], candidates: 0)).state == .unknown)
        #expect(unavailable(try decode(report(frames: [], candidates: 0))))
    }

    @Test func differentPidSessionAndReusedPidAreRejected() throws {
        let original = report(frames: [frame])
        let data = try JSONEncoder().encode(original)
        var different = receipt
        different.webSession = String(repeating: "b", count: 32)
        #expect(unavailable(GuardWebEnvironmentReader.decode(data, client: client, receipt: different, now: now)))
        let reused = GuardClient(path: client.path, version: "test", pid: 123, launchedAt: now, runningInstanceCount: 1)
        #expect(unavailable(GuardWebEnvironmentReader.decode(data, client: reused, receipt: receipt, now: now)))
        let wrongPID = GuardWebReport(protocol: 1, session: session, pid: 999, capturedAt: original.capturedAt, candidateCount: 1, failedCount: 0, frames: [frame])
        #expect(unavailable(try decode(wrongPID)))
    }

    @Test func expiredFutureAndPreLaunchReadingsAreRejected() throws {
        for date in [now.addingTimeInterval(-100), now.addingTimeInterval(10), now.addingTimeInterval(-20)] {
            let value = GuardWebReport(protocol: 1, session: session, pid: 123, capturedAt: date.timeIntervalSince1970 * 1000, candidateCount: 1, failedCount: 0, frames: [frame])
            #expect(unavailable(try decode(value)))
        }
    }

    @Test func malformedProtocolCountsAndNonClaudeContextsAreRejected() throws {
        let badContext = GuardWebFrame(context: "https://evil/", language: "en-US", languages: ["en-US"], locale: "en-US", timeZone: "America/Los_Angeles")
        #expect(unavailable(try decode(report(frames: [badContext]))))
        #expect(unavailable(try decode(report(frames: [frame], candidates: 0))))
        let wrongProtocol = GuardWebReport(protocol: 2, session: session, pid: 123, capturedAt: now.timeIntervalSince1970 * 1000, candidateCount: 1, failedCount: 0, frames: [frame])
        #expect(unavailable(try decode(wrongProtocol)))
        let large = Data(repeating: 32, count: 32769)
        #expect(unavailable(GuardWebEnvironmentReader.decode(large, client: client, receipt: receipt, now: now)))
    }

    @Test func disabledMissingAndStoppedStatesNeverPass() {
        for reason: GuardWebUnavailable in [.notRunning, .missingModule, .outdatedModule, .needsRelaunch, .waitingForPage, .unreadable, .stale] {
            let result = GuardWebEvaluator.finding(profile: profile, state: .unavailable(reason), launchPending: false)
            #expect(result.state != .passed)
        }
        var disabled = profile
        disabled.enabled = false
        let result = GuardWebEvaluator.finding(profile: disabled, state: .observed(report(frames: [frame])), launchPending: false)
        #expect(result.state == .information)
        #expect(result.value.chinese == "未启用")
    }

    @Test func savedReceiptWithoutNewSessionRemainsDecodable() throws {
        var old = receipt
        old.webSession = nil
        let raw = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(LaunchReceipt.self, from: raw).webSession == nil)
    }

    @Test func comparisonPreservesDifferentPageValuesInsteadOfPickingTheFirst() {
        let wrong = GuardWebFrame(context: "Claude Desktop", language: "en-US", languages: ["en-US"], locale: "en-US", timeZone: "Asia/Shanghai")
        let state = GuardWebState.observed(report(frames: [frame, wrong]))
        let reading = GuardWebEvaluator.reading(.timezone, profile: profile, state: state)
        #expect(reading.values == ["America/Los_Angeles", "Asia/Shanghai"])
        #expect(reading.state == .attention)
        #expect(GuardWebEvaluator.reading(.region, profile: profile, state: state).values == ["en-US"])
        #expect(GuardWebEvaluator.reading(.region, profile: profile, state: state).state == .passed)
    }

    @Test func comparisonNeverFillsUnavailableDataWithTheSavedProfile() {
        for reason: GuardWebUnavailable in [.notRunning, .waitingForPage, .stale, .unreadable, .needsRelaunch] {
            for field in GuardWebField.allCases {
                let value = GuardWebEvaluator.reading(field, profile: profile, state: .unavailable(reason))
                #expect(value.text == "—")
                #expect(value.state == .unknown)
            }
        }
        let partial = GuardWebState.observed(report(frames: [frame], candidates: 2, failed: 1))
        #expect(GuardWebEvaluator.reading(.language, profile: profile, state: partial).text == "en-US")
        #expect(GuardWebEvaluator.reading(.language, profile: profile, state: partial).state == .unknown)
        var disabled = profile
        disabled.enabled = false
        #expect(GuardWebEvaluator.reading(.language, profile: disabled, state: .observed(report(frames: [frame]))).state == .unknown)
    }

    @Test func comparisonChecksThePrimaryPreferredLanguageAndCanonicalValues() {
        let wrongPrimary = GuardWebFrame(context: "claude.ai", language: "en-US", languages: ["zh-CN"], locale: "en-US", timeZone: "US/Pacific")
        let state = GuardWebState.observed(report(frames: [wrongPrimary]))
        #expect(GuardWebEvaluator.reading(.language, profile: profile, state: state).state == .attention)
        #expect(GuardWebEvaluator.reading(.region, profile: profile, state: state).state == .passed)
        #expect(GuardWebEvaluator.reading(.timezone, profile: profile, state: state).state == .passed)
    }

    @Test func geographicLabelsDecodeWithoutRequiringCityOrIP() throws {
        let withCity = try JSONDecoder().decode(GuardCountryResponse.self, from: Data(#"{"country":"TR","city":"Istanbul","subdivision":"34"}"#.utf8))
        #expect(withCity.country == "TR")
        #expect(withCity.city == "Istanbul")
        #expect(withCity.subdivision == "34")
        let countryOnly = try JSONDecoder().decode(GuardCountryResponse.self, from: Data(#"{"country":"TR"}"#.utf8))
        #expect(countryOnly.city == nil)
        #expect(countryOnly.subdivision == nil)
    }

    @MainActor @Test func sessionOnlyEnablesCollectorForConfiguredLaunches() throws {
        let configured = try GuardLauncher.configuration(profile: profile, webSession: session)
        #expect(configured.environment[GuardWebEnvironmentReader.sessionKey] == session)
        #expect(configured.environment["TZ"] == profile.timeZoneIdentifier)
        #expect(!configured.arguments.contains { $0.contains("remote-debugging") })
        var disabled = profile
        disabled.enabled = false
        let plain = try GuardLauncher.configuration(profile: disabled, webSession: session)
        #expect(plain.environment[GuardWebEnvironmentReader.sessionKey] == nil)
        #expect(plain.environment["TZ"] == nil)
    }

    @Test func privateReaderRejectsSymlinksPublicPermissionsAndOversizedData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GuardWebTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("sample.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(GuardWebEnvironmentReader.privateData(at: file, maxBytes: 100) == Data("{}".utf8))
        #expect(GuardWebEnvironmentReader.privateData(at: file, maxBytes: 1) == nil)
        let link = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(GuardWebEnvironmentReader.privateData(at: link, maxBytes: 100) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(GuardWebEnvironmentReader.privateData(at: file, maxBytes: 100) == nil)
    }
}
