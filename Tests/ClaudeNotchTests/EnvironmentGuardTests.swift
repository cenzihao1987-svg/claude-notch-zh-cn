import AppKit
import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct EnvironmentGuardTests {
    let profile = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(signature: GuardSignature = .valid(publisher: "TEST"), running: Bool = false,
                          process: GuardProcessConfiguration? = nil) -> GuardSnapshot {
        .init(client: .init(path: "/Applications/Claude.app", version: "test", pid: running ? 42 : nil,
                            launchedAt: running ? now : nil, signature: signature, process: process,
                            runningInstanceCount: running ? 1 : 0), checkedAt: now)
    }

    private func findings(_ snapshot: GuardSnapshot, enabled: Bool = true) -> [GuardFinding] {
        GuardEvaluator.findings(profile: profile, snapshot: snapshot, networkEnabled: enabled, now: now)
    }

    @Test func defaultProfileDoesNotGuessARegionOrTimezone() {
        let empty = GuardProfile()
        #expect(!empty.enabled)
        #expect(!empty.isValid)
        #expect(empty.countryCode == nil)
        #expect(empty.timeZoneIdentifier.isEmpty)
        #expect(profile.isValid)
    }

    @Test func regionDefaultsAndManualOverridesSurvivePersistence() throws {
        var value = GuardProfile()
        value.selectRegion("US")
        #expect(value.timeZoneIdentifier == "America/Los_Angeles")
        value.selectTimeZone("America/New_York")
        value.selectRegion("JP")
        #expect(value.timeZoneIdentifier == "Asia/Tokyo")
        value = try JSONDecoder().decode(GuardProfile.self, from: JSONEncoder().encode(value))
        value.selectRegion("US")
        #expect(value.timeZoneIdentifier == "America/New_York")
        value.selectRegion("US")
        #expect(value.timeZoneIdentifier == "America/New_York")
    }

    @Test func legacyProfilesKeepTheirChosenTimezone() throws {
        let data = Data(#"{"enabled":true,"languageCode":"en-US","localeIdentifier":"en_US","timeZoneIdentifier":"America/Chicago"}"#.utf8)
        var value = try JSONDecoder().decode(GuardProfile.self, from: data)
        value.selectRegion("JP")
        value.selectRegion("US")
        #expect(value.timeZoneIdentifier == "America/Chicago")
        #expect(GuardProfile.defaultTimeZones.values.allSatisfy { TimeZone.knownTimeZoneIdentifiers.contains($0) })
    }

    @Test func rejectsInvalidTimezoneAndLocale() {
        var bad = profile
        bad.timeZoneIdentifier = "Made/Up"
        #expect(!bad.isValid)
        bad = profile
        bad.localeIdentifier = "en_XX"
        #expect(!bad.isValid)
    }

    @Test func pendingLocaleAndTimezoneAreOneAction() {
        let rows = findings(snapshot(signature: .local))
        #expect(GuardSummary(findings: rows, checked: true) == .attention(2))
        #expect(Set(rows.compactMap(\.actionID)) == ["launch", "signature"])
    }

    @Test func matchingArgumentsDoNotVerifyChromiumOrAccountSafety() {
        let process = GuardProcessConfiguration(language: profile.languageCode,
                                               appleLanguages: "(en-US)", locale: "en_US", timeZone: profile.timeZoneIdentifier)
        let rows = findings(snapshot(running: true, process: process), enabled: false)
        #expect(rows.first { $0.id == "launch" }?.state == .passed)
        #expect(rows.first { $0.id == "chromium" }?.state == .unknown)
        #expect(GuardSummary(findings: rows, checked: true) == .unverified)
    }

    @Test func unreadableProcessIsUnknownRatherThanPassed() {
        let rows = findings(snapshot(running: true))
        #expect(rows.first { $0.id == "launch" }?.state == .unknown)
        #expect(!rows.contains { $0.actionID == "launch" })
    }

    @Test func externallyLaunchedAndChangedProfilesNeedRelaunch() {
        let rows = findings(snapshot(running: true, process: .init()))
        #expect(rows.first { $0.id == "launch" }?.actionID == "launch")
        #expect(rows.first { $0.id == "launch" }?.state == .pending)
    }

    @Test func matchingOneOfSeveralInstancesDoesNotClearTheLaunchIssue() {
        let process = GuardProcessConfiguration(language: "en-US", appleLanguages: "(en-US)", locale: "en_US", timeZone: "America/Los_Angeles")
        var value = snapshot(running: true, process: process)
        value.client?.runningInstanceCount = 2
        #expect(findings(value).first { $0.id == "launch" }?.state == .attention)
        #expect(findings(value).first { $0.id == "launch" }?.actionID == "launch")
    }

    @Test func failedAndMissingSignaturesCannotBeShownAsPassed() {
        let bad = findings(snapshot(signature: .invalid(code: -67030)))
        #expect(bad.first { $0.id == "signature" }?.state == .attention)
        let missing = findings(snapshot(signature: .unavailable))
        #expect(missing.first { $0.id == "signature" }?.state == .unknown)
    }

    @Test func missingInstallationCannotProduceAnAllClear() {
        let rows = findings(.init(checkedAt: now))
        #expect(GuardSummary(findings: rows, checked: true) == .attention(1))
        #expect(rows.first?.id == "installation")
    }

    @Test func staleOrFailedNetworkCannotBecomePassedOrCauseAStaleAlert() {
        var value = snapshot()
        value.network = .init(countryCode: "CN", fetchedAt: now.addingTimeInterval(-901))
        value.networkInvalidated = false
        #expect(findings(value).first { $0.id == "network" }?.state == .unknown)
        #expect(!findings(value).contains { $0.actionID == "network" })
        value.network = .init(countryCode: "US", fetchedAt: now)
        value.networkInvalidated = true
        #expect(findings(value).first { $0.id == "network" }?.state == .unknown)
    }

    @Test func freshUnsupportedOrMismatchedCountryAddsOneReferenceIssue() {
        var value = snapshot()
        value.network = .init(countryCode: "CN", fetchedAt: now)
        value.networkInvalidated = false
        #expect(findings(value).filter { $0.actionID == "network" }.count == 1)
        #expect(findings(value).first { $0.id == "network" }?.detail.english.contains("Claude's actual route is unverified") == true)
        #expect(findings(value, enabled: false).first { $0.id == "network" }?.state == .information)
    }

    @Test func availabilityListUsesConsumerRegions() {
        #expect(GuardSupportedRegions.codes.contains("US"))
        #expect(GuardSupportedRegions.codes.contains("TW"))
        #expect(!GuardSupportedRegions.codes.contains("CN"))
        #expect(!GuardSupportedRegions.codes.contains("HK"))
    }

    @Test func launchReceiptDoesNotSurvivePIDReuseOrDifferentAppPaths() {
        let receipt = LaunchReceipt(pid: 42, launchedAt: now, appPath: "/Applications/Claude.app", profile: profile)
        let same = snapshot(running: true).client!
        #expect(receipt.matches(same))
        let reused = GuardClient(path: same.path, version: same.version, pid: 42, launchedAt: now.addingTimeInterval(10))
        #expect(!receipt.matches(reused))
    }

    @Test func processParserKeepsOnlyWhitelistedLaunchFields() {
        let data = processData(arguments: ["Claude", "--lang=en-US", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US", "--some-private-value=ignored"],
                               environment: ["PRIVATE_TOKEN=never-retain-this", "TZ=America/Los_Angeles", "LANG=zh_CN.UTF-8"])
        let read = GuardProcessReader.parse(data)
        #expect(read?.matches(profile) == true)
        #expect(read?.timeZone == "America/Los_Angeles")
    }

    @Test func rejectsTruncatedAndInvalidProcessBuffers() {
        #expect(GuardProcessReader.parse(Data([1, 2])) == nil)
        #expect(GuardProcessReader.parse(Data(repeating: 255, count: 20)) == nil)
        var data = processData(arguments: ["Claude", "--lang=en-US"], environment: [])
        data.removeLast(4)
        #expect(GuardProcessReader.parse(data) == nil)
    }

    @Test func readsOwnProcessWithoutNeedingAccountAccess() {
        #expect(GuardProcessReader.read(pid: ProcessInfo.processInfo.processIdentifier) != nil)
    }

    @MainActor @Test func launcherUsesOnlyPerApplicationSettings() throws {
        let config = try GuardLauncher.configuration(profile: profile)
        #expect(config.environment == ["TZ": "America/Los_Angeles"])
        #expect(config.arguments == profile.arguments)
        #expect(!config.createsNewApplicationInstance)
        #expect(!config.allowsRunningApplicationSubstitution)
        let normal = try GuardLauncher.configuration(profile: GuardProfile())
        #expect(normal.arguments.isEmpty)
        #expect(normal.environment.isEmpty)
        var invalid = profile
        invalid.timeZoneIdentifier = "Invalid"
        #expect(throws: GuardLaunchError.self) { try GuardLauncher.configuration(profile: invalid) }
    }

    @MainActor @Test func allGuardIconsAreBundledAsNativeVectors() throws {
        for glyph in GuardGlyph.allCases {
            let image = try #require(GuardIconAssets.image(glyph))
            #expect(image.isTemplate)
            #expect(image.representations.contains { $0 is NSPDFImageRep })
            #expect(image.size.width == 24)
            #expect(image.size.height == 24)
            if glyph.hasLargeVariant {
                let large = try #require(GuardIconAssets.image(glyph, large: true))
                #expect(large.representations.contains { $0 is NSPDFImageRep })
            }
        }
    }

    @MainActor @Test func profilePersistsInAnIsolatedDefaultsDomain() throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.GuardTests.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.updateProfile(profile)
        let next = EnvironmentGuardService(defaults: defaults)
        #expect(next.profile == profile)
        #expect(next.receipt == nil)
    }

    #if DEBUG
    @MainActor @Test func designFixtureIsIsolatedAndCannotLaunchClaude() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ClaudeNotch.GuardVisualTests.\(UUID().uuidString)"))
        let service = EnvironmentGuardService(defaults: defaults)
        service.loadDesignPreview()
        #expect(service.isDesignPreview)
        #expect(service.summary == .attention(3))
        #expect(service.snapshot.network?.countryCode == "TR")
        service.updateProfile(service.profile)
        service.setNetworkChecksEnabled(false)
        service.setNetworkChecksEnabled(true)
        service.refresh(force: true)
        #expect(defaults.data(forKey: EnvironmentGuardService.profileKey) == nil)
        #expect(defaults.object(forKey: "environmentGuard.networkChecksEnabled") == nil)
        #expect(await service.launchClaude() == false)
        #expect(service.receipt == nil)
    }
    #endif

    private func processData(arguments: [String], environment: [String]) -> Data {
        var argc = Int32(arguments.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(contentsOf: Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8) + [0, 0, 0])
        for value in arguments + environment { data.append(contentsOf: Array(value.utf8) + [0]) }
        return data
    }
}
