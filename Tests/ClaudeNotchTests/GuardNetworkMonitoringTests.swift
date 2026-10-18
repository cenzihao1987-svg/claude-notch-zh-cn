import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardNetworkMonitoringTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func exit(_ ip: String, _ country: String = "TR", seconds: Double = 0) -> GuardExit {
        GuardExit(.init(countryCode: country, fetchedAt: date.addingTimeInterval(seconds), ip: ip, timeZone: country == "TR" ? "Europe/Istanbul" : "Asia/Singapore"), activity: .active)!
    }

    private func accept(_ tracker: inout GuardNetworkTracker, _ ip: String, _ country: String = "TR", seconds: Double) {
        tracker.observe(exit(ip, country, seconds: seconds))
        tracker.observe(exit(ip, country, seconds: seconds + 5), verification: .verified)
    }

    private func extremeTracker() -> GuardNetworkTracker {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US"))
        accept(&tracker, "203.0.113.2", "TR", seconds: 60)
        accept(&tracker, "203.0.113.3", "SG", seconds: 300)
        return tracker
    }

    @Test func toolLaunchSnapshotSurvivesPeriodicChangesAndConfirmation() {
        var tracker = GuardNetworkTracker()
        let a = exit("203.0.113.1", "SG")
        tracker.observe(a)
        accept(&tracker, "203.0.113.2", "MY", seconds: 60)
        #expect(tracker.alert?.current.country == "MY")
        #expect(tracker.history.lastLaunch == a)
        let rejected = tracker.confirm(exit("203.0.113.9", "MY", seconds: 65))
        let confirmed = tracker.confirm(exit("203.0.113.2", "MY", seconds: 65))
        #expect(!rejected)
        #expect(confirmed)
        #expect(tracker.history.lastLaunch == a)
        var nextLaunch = GuardNetworkTracker(history: tracker.history)
        nextLaunch.observe(exit("203.0.113.2", "MY", seconds: 100))
        #expect(nextLaunch.previousLaunch == a)
        #expect(nextLaunch.history.lastLaunch?.country == "MY")
        #expect(nextLaunch.history.geographicTransitions?.count == 1)
    }

    @Test func remoteChangesNeedFiveSecondRepeatAndLocationAgreement() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US"))
        tracker.observe(exit("203.0.113.2", "TR", seconds: 60))
        tracker.observe(exit("203.0.113.2", "TR", seconds: 64), verification: .verified)
        #expect(tracker.alert == nil)
        tracker.observe(exit("203.0.113.2", "TR", seconds: 69), verification: .conflict)
        #expect(tracker.assessment(at: date.addingTimeInterval(69)).kind == .unverified)
        #expect(tracker.assessment(at: date.addingTimeInterval(69)).minimumTotal == 0)
        #expect(tracker.history.geographicTransitions == nil)
        tracker.observe(exit("203.0.113.2", "TR", seconds: 74), verification: .unavailable)
        #expect(tracker.alert == nil)
        tracker.observe(exit("203.0.113.2", "TR", seconds: 80), verification: .verified)
        #expect(tracker.assessment(at: date.addingTimeInterval(80)).minimumTotal == 50)
    }

    @Test func failedProbeAndStaleSampleCannotConfirmANewExit() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US"))
        tracker.observe(exit("203.0.113.2", "TR", seconds: 60))
        tracker.invalidateCandidate()
        tracker.observe(exit("203.0.113.2", "TR", seconds: 120), verification: .verified)
        tracker.observe(exit("203.0.113.2", "TR", seconds: 119), verification: .verified)
        #expect(tracker.alert == nil)
        tracker.observe(exit("203.0.113.2", "TR", seconds: 125), verification: .verified)
        #expect(tracker.alert?.countryChanged == true)
    }

    @Test func sameCountryIPRotationNeverBecomesGeographicRisk() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1"))
        for index in 2...30 { accept(&tracker, "203.0.113.\(index)", seconds: Double(index * 10)) }
        let behavior = tracker.assessment(at: date.addingTimeInterval(305))
        #expect(behavior.kind == nil)
        #expect(behavior.points == 0)
        #expect(behavior.minimumTotal == 0)
        #expect(tracker.alert == nil)
        #expect(tracker.history.lastLaunch?.ip == "203.0.113.1")
        #expect(GuardExit.normalizedIP("2001:0db8:0:0:0:0:0:1") == "2001:db8::1")
        #expect(GuardExit.normalizedIP("not-an-ip") == nil)
        #expect(GuardExit.normalizedIP("::ffff:203.0.113.1") == "203.0.113.1")
    }

    @Test func multipleCountriesAndRoundTripReachExtremeWithoutDoubleCounting() {
        let tracker = extremeTracker()
        let behavior = tracker.assessment(at: date.addingTimeInterval(305))
        #expect(behavior.kind == .repeated)
        #expect(behavior.points == 40)
        #expect(behavior.minimumTotal == 80)
        #expect(behavior.crossRegionCount == 2)
        #expect(behavior.regionCount == 3)
        var roundTrip = GuardNetworkTracker()
        roundTrip.observe(exit("203.0.113.1", "US"))
        accept(&roundTrip, "203.0.113.2", "TR", seconds: 60)
        accept(&roundTrip, "203.0.113.3", "US", seconds: 120)
        #expect(roundTrip.assessment(at: date.addingTimeInterval(125)).kind == .roundTrip)
        #expect(roundTrip.assessment(at: date.addingTimeInterval(125)).regionCount == 2)
    }

    @Test func ignoringAndRestartingPreserveIncidentAndNextEventWarnsAgain() {
        var tracker = extremeTracker()
        tracker.ignoreWarning(at: date.addingTimeInterval(305))
        #expect(tracker.history.ignoredWarning == tracker.assessment(at: date.addingTimeInterval(305)).identifier)
        let confirmed = tracker.confirm(exit("203.0.113.3", "SG", seconds: 305))
        #expect(confirmed)
        #expect(tracker.assessment(at: date.addingTimeInterval(305)).minimumTotal == 80)
        var restarted = GuardNetworkTracker(history: tracker.history)
        restarted.observe(exit("203.0.113.3", "SG", seconds: 400))
        #expect(restarted.assessment(at: date.addingTimeInterval(400)).minimumTotal == 80)
        accept(&restarted, "203.0.113.4", "US", seconds: 500)
        #expect(restarted.history.ignoredWarning != restarted.assessment(at: date.addingTimeInterval(505)).identifier)
    }

    @Test func stableMonitoringReducesFloorsButIdleTimeDoesNot() {
        var tracker = extremeTracker()
        #expect(tracker.assessment(at: date.addingTimeInterval(90000)).minimumTotal == 80)
        for minute in 1...120 { tracker.observe(exit("203.0.113.3", "SG", seconds: 305 + Double(minute * 60))) }
        #expect(tracker.assessment(at: date.addingTimeInterval(7505)).minimumTotal == 50)
        // Normal same-country reassignments must not reset the recovery clock.
        accept(&tracker, "203.0.113.8", "SG", seconds: 7565)
        #expect((tracker.history.incident?.stableSeconds ?? 0) >= 7200)
        var second = 7570.0
        while second < 87000 {
            second += 60
            tracker.observe(exit("203.0.113.8", "SG", seconds: second))
        }
        #expect(tracker.assessment(at: date.addingTimeInterval(second)).minimumTotal == 0)
        var gap = extremeTracker()
        gap.observe(exit("203.0.113.3", "SG", seconds: 20000))
        #expect(gap.assessment(at: date.addingTimeInterval(20000)).minimumTotal == 80)
        #expect(gap.history.incident?.stableSeconds == 0)
    }

    @Test func actualLastSeenTimeAndOvernightGapHaveDifferentOutcomes() {
        var active = GuardNetworkTracker()
        active.observe(exit("203.0.113.1", "US"))
        active.observe(exit("203.0.113.1", "US", seconds: 10000))
        accept(&active, "203.0.113.2", "TR", seconds: 10060)
        #expect(active.assessment(at: date.addingTimeInterval(10065)).minimumTotal == 50)
        var overnight = GuardNetworkTracker()
        overnight.observe(exit("203.0.113.1", "US"))
        accept(&overnight, "203.0.113.2", "TR", seconds: 28800)
        #expect(overnight.assessment(at: date.addingTimeInterval(28805)).minimumTotal == 0)
        #expect(overnight.assessment(at: date.addingTimeInterval(28805)).points == 10)
    }

    @Test func adjacentCountriesAccumulateWithoutImpossibleTravelAndWindowExpires() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "SG"))
        for index in 1...4 { accept(&tracker, "203.0.113.\(index + 1)", index.isMultiple(of: 2) ? "SG" : "MY", seconds: Double(index * 600)) }
        let result = tracker.assessment(at: date.addingTimeInterval(2405))
        #expect(result.kind == .cumulative)
        #expect(result.crossRegionCount == 4)
        #expect(result.regionCount == 2)
        #expect(result.points == 20)
        #expect(result.minimumTotal == 0)
        #expect(tracker.assessment(at: date.addingTimeInterval(90000)).points == 0)
        #expect(!GuardGeography.isRemote("US", "CA"))
        #expect(!GuardGeography.isRemote("SG", "MY"))
        #expect(!GuardGeography.isRemote("RU", "CN"))
    }

    @Test func dualStackMismatchIsNotTravelAndIdenticalIPCountryChangeIsUnverified() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "TR"))
        tracker.observe(exit("2001:db8::1", "SG", seconds: 30))
        #expect(tracker.assessment(at: date.addingTimeInterval(30)).kind == .familyMismatch)
        #expect(tracker.assessment(at: date.addingTimeInterval(30)).crossRegionCount == 0)
        #expect(tracker.assessment(at: date.addingTimeInterval(30)).points == 20)
        var same = GuardNetworkTracker()
        same.observe(exit("203.0.113.1", "TR"))
        accept(&same, "203.0.113.1", "SG", seconds: 60)
        #expect(same.assessment(at: date.addingTimeInterval(65)).locationUnverified)
        #expect(same.history.geographicTransitions == nil)
    }

    @Test func bothAddressFamiliesMovingTogetherCountAsOneGeographicSwitch() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US"))
        tracker.observe(exit("2001:db8::1", "US", seconds: 1))
        accept(&tracker, "203.0.113.2", "TR", seconds: 60)
        accept(&tracker, "2001:db8::2", "TR", seconds: 70)
        let result = tracker.assessment(at: date.addingTimeInterval(75))
        #expect(result.crossRegionCount == 1)
        #expect(result.anomalousCount == 1)
        #expect(result.minimumTotal == 50)
    }

    @Test func cityChangesAndReturningFromAReassignedSameCountryIPDoNotAddTravel() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "SG"))
        accept(&tracker, "203.0.113.2", "MY", seconds: 60)
        accept(&tracker, "203.0.113.8", "MY", seconds: 120)
        let accepted = tracker.confirm(exit("203.0.113.8", "MY", seconds: 125))
        #expect(accepted)
        #expect(tracker.assessment(at: date.addingTimeInterval(125)).crossRegionCount == 1)
        let city = GuardExit(.init(countryCode: "MY", fetchedAt: date.addingTimeInterval(180), city: "Another city", ip: "203.0.113.8"), activity: .active)!
        tracker.observe(city)
        #expect(tracker.assessment(at: date.addingTimeInterval(180)).crossRegionCount == 1)
    }

    @Test func launchAfterAnOvernightAddressFamilyChangeStillRecordsTheRegionChange() {
        var old = GuardNetworkTracker()
        old.observe(exit("203.0.113.1", "US"))
        var next = GuardNetworkTracker(history: old.history)
        accept(&next, "2001:db8::1", "TR", seconds: 28800)
        let result = next.assessment(at: date.addingTimeInterval(28805))
        #expect(result.kind == .countryChange)
        #expect(result.crossRegionCount == 1)
        #expect(result.minimumTotal == 0)
    }

    @Test func legacyIPCounterNeverMigratesIntoGeographicRisk() throws {
        let old = GuardNetworkHistory(lastLaunch: exit("203.0.113.1"),
            transitions: (1...10).map { exit("203.0.113.\($0)", seconds: Double($0)) })
        let restored = try JSONDecoder().decode(GuardNetworkHistory.self, from: JSONEncoder().encode(old))
        var tracker = GuardNetworkTracker(history: restored)
        tracker.observe(exit("203.0.113.10", seconds: 60))
        #expect(tracker.assessment(at: date.addingTimeInterval(60)).minimumTotal == 0)
    }

    @Test func secondLocationSourceMustMatchTheExactIPAndCountry() {
        let expected = exit("203.0.113.1", "TR")
        let good = Data(#"{"success":true,"ip":"203.0.113.1","country_code":"TR"}"#.utf8)
        let conflict = Data(#"{"success":true,"ip":"203.0.113.1","country_code":"US"}"#.utf8)
        let wrongIP = Data(#"{"success":true,"ip":"203.0.113.2","country_code":"TR"}"#.utf8)
        let failure = Data(#"{"success":false,"message":"Rate limit exceeded"}"#.utf8)
        #expect(GuardLocationVerifier.evaluate(good, expected: expected) == .verified)
        #expect(GuardLocationVerifier.evaluate(conflict, expected: expected) == .conflict)
        #expect(GuardLocationVerifier.evaluate(wrongIP, expected: expected) == .unavailable)
        #expect(GuardLocationVerifier.evaluate(failure, expected: expected) == .unavailable)
        #expect(GuardLocationVerifier.evaluate(Data("invalid".utf8), expected: expected) == .unavailable)
    }

    @Test func knownAnomaliesPersistThroughMissingDataWithoutFabricatedComponents() {
        let environment = GuardSystemEnvironment(languageCode: "en-US", localeIdentifier: "en_TR", timeZoneIdentifier: "Europe/Istanbul")
        var snapshot = GuardSnapshot()
        snapshot.networkBehavior = .init(kind: .anomalous, points: 30, minimumTotal: 50)
        #expect(GuardRiskEvaluator.assess(environment: environment, snapshot: snapshot, networkEnabled: true, now: date).total == 50)
        snapshot.networkBehavior = .init(kind: .unverified, locationUnverified: true)
        #expect(GuardRiskEvaluator.assess(environment: environment, snapshot: snapshot, networkEnabled: true, now: date).total == nil)
    }

    @Test func mismatchScoresAreDeduplicatedAndPreviewRespondsToChanges() {
        let now = date
        var snapshot = GuardSnapshot(client: .init(path: "/Applications/Claude.app", version: "fixture", pid: nil, launchedAt: nil, signature: .local),
            network: .init(countryCode: "SG", fetchedAt: now, ip: "203.0.113.5", timeZone: "Asia/Singapore"), networkInvalidated: false)
        let matching = GuardSystemEnvironment(languageCode: "en-US", localeIdentifier: "en_SG", timeZoneIdentifier: "Asia/Singapore")
        let different = GuardSystemEnvironment(languageCode: "en-US", localeIdentifier: "en_TR", timeZoneIdentifier: "Europe/Istanbul")
        #expect(GuardRiskEvaluator.assess(environment: matching, snapshot: snapshot, networkEnabled: true, now: now, estimating: true).total == 10)
        #expect(GuardRiskEvaluator.assess(environment: different, snapshot: snapshot, networkEnabled: true, now: now, estimating: true).local == 20)
        snapshot.networkBehavior = .init(kind: .anomalous, points: 30, minimumTotal: 50)
        snapshot.proxyCheck = .init(conflict: true, inspected: true)
        let risk = GuardRiskEvaluator.assess(environment: matching, snapshot: snapshot, networkEnabled: true, now: now, estimating: true)
        #expect(risk.network == 40)
        #expect(risk.total == 50)
    }

    @Test func historyAndEveryChangedExitAreStoredPrivately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-history-\(UUID().uuidString)")
        let store = GuardHistoryStore(url: directory.appendingPathComponent("network-history.json"))
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1"))
        try store.save(tracker.history)
        try store.appendObservation(exit("203.0.113.1"), kind: "tool-start")
        try store.appendObservation(exit("203.0.113.2"), kind: "exit-change")
        #expect(try store.load() == tracker.history)
        for file in [store.url, directory.appendingPathComponent("network-exits.jsonl")] {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let lines = try String(contentsOf: directory.appendingPathComponent("network-exits.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    @MainActor @Test func manualOverrideLastsOnlyForThisToolRun() throws {
        let suite = "guard-follow-ip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = GuardHistoryStore(url: directory.appendingPathComponent("network-history.json"))
        let service = EnvironmentGuardService(defaults: defaults, historyStore: store)
        func observation(_ country: String, _ zone: String) -> GuardNetworkObservation {
            .init(countryCode: country, fetchedAt: .now.addingTimeInterval(-0.01), ip: "203.0.113.1", timeZone: zone)
        }
        #expect(service.applyNetworkObservation(observation("SG", "Asia/Singapore")))
        #expect(service.profile.localeIdentifier == "en_SG")
        #expect(service.profile.timeZoneIdentifier == "Asia/Singapore")
        var profile = service.profile; profile.selectRegion("TR"); profile.selectTimeZone("Europe/Istanbul")
        service.updateProfile(profile)
        #expect(!service.followingIP)
        #expect(service.applyNetworkObservation(observation("SG", "Asia/Singapore")))
        #expect(service.profile.localeIdentifier == "en_TR")
        let restarted = EnvironmentGuardService(defaults: defaults, historyStore: store)
        #expect(restarted.followingIP)
        #expect(restarted.applyNetworkObservation(observation("SG", "Asia/Singapore")))
        #expect(restarted.profile.localeIdentifier == "en_SG")
        #expect(restarted.profile.timeZoneIdentifier == "Asia/Singapore")
        #expect(!restarted.applyNetworkObservation(.init(countryCode: "XX", fetchedAt: .now, ip: "bad")))
    }

    @Test func proxyScannerDoesNotExecuteOrExposeSecrets() {
        let lines = "# export HTTPS_PROXY=ignore\nexport HTTPS_PROXY=http://private-password@127.0.0.1:7897\necho $(touch should-not-execute)\n"
        let values = GuardExecutionInspector.definitions(in: lines, source: ".zshrc")
        #expect(values == [".zshrc:2 · HTTPS_PROXY"])
        #expect(!values.joined().contains("private-password"))
        #expect(GuardExecutionInspector.endpointIdentity("http://user:secret@localhost:7897") == "localhost:7897")
    }

    @Test func runtimeOnlyAttributesTrustedDescendantsAndDoesNotGuessCloud() {
        let client = GuardClient(path: "/Applications/Claude.app", version: "fixture", pid: 100, launchedAt: date)
        let processes: [GuardRuntimeProcess] = [
            .init(pid: 100, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            .init(pid: 101, parent: 100, path: "/Applications/Claude.app/Contents/Resources/claude"),
            .init(pid: 102, parent: 100, path: "/tmp/untrusted/claude"),
            .init(pid: 103, parent: 1, path: "/Applications/Claude.app/Contents/Resources/claude")]
        let result = GuardExecutionInspector.runtimeCheck(client: client, processes: processes)
        #expect(result.execution == ["/Applications/Claude.app/Contents/Resources/claude · PID 101"])
        #expect(result.location.chinese.contains("未核验"))
        #expect(result.points == 5)
        let empty = GuardExecutionInspector.runtimeCheck(client: client, processes: [])
        #expect(empty.location.chinese.contains("未确认"))
        #expect(!empty.location.chinese.contains("已确认云端"))
    }
    @Test func proxyEnvironmentParserRetainsOnlyAllowlistedKeys() {
        var data = Data(); var argc: Int32 = 1
        withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("/bin/zsh\0\0/bin/zsh\0HTTPS_PROXY=http://user:fixture@localhost:7897\0API_TOKEN=must-not-retain\0TZ=Asia/Shanghai\0\0".utf8))
        let parsed = GuardProcessReader.parseProxyEnvironment(data)
        #expect(parsed?.keys.sorted() == ["HTTPS_PROXY"])
        #expect(parsed?["API_TOKEN"] == nil)
    }

    @Test func addressFamilyAlternationIsNotFrequentIPRotation() {
        var tracker = GuardNetworkTracker()
        for index in 0...10 {
            tracker.observe(exit(index.isMultiple(of: 2) ? "203.0.113.1" : "2001:db8::1", seconds: Double(index * 30)))
        }
        #expect(tracker.assessment(at: date.addingTimeInterval(300)).kind == nil)
    }

    @Test func knownExtremeChurnCannotBeHiddenByMissingOtherData() {
        #expect(GuardRiskAssessment(local: nil, network: nil, client: nil, minimumTotal: 80).total == 80)
        #expect(GuardRiskAssessment(local: nil, network: nil, client: nil).total == nil)
    }

    @MainActor @Test func unreadableHistoryIsPreservedAndCannotBeReportedAsRecorded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("network-history.json")
        let original = Data("invalid history must remain available for recovery".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let defaults = UserDefaults(suiteName: "guard-unreadable-\(UUID().uuidString)")!
        let service = EnvironmentGuardService(defaults: defaults, historyStore: .init(url: file))
        #expect(service.applyNetworkObservation(.init(countryCode: "TR", fetchedAt: .now.addingTimeInterval(-0.01), ip: "203.0.113.1", timeZone: "Europe/Istanbul")))
        #expect(service.historyError)
        #expect(try Data(contentsOf: file) == original)
        #expect(service.snapshot.historyUnavailable)
        service.stop()
    }

}
