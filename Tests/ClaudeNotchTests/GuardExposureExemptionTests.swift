import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardExposureExemptionTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func exit(_ ip: String, _ country: String, _ seconds: Double, _ activity: GuardDesktopActivity) -> GuardExit {
        GuardExit(.init(countryCode: country, fetchedAt: date.addingTimeInterval(seconds), ip: ip), activity: activity)!
    }
    private func accept(_ tracker: inout GuardNetworkTracker, _ ip: String, _ country: String, _ seconds: Double, _ activity: GuardDesktopActivity) {
        tracker.observe(exit(ip, country, seconds, activity))
        tracker.observe(exit(ip, country, seconds + 5, activity), verification: .verified)
    }

    @Test func inactiveCountryHopsAreRecordedButNeverCountedAndFirstUseIsABaseline() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US", 0, .inactive))
        accept(&tracker, "203.0.113.2", "TR", 20, .inactive)
        accept(&tracker, "203.0.113.3", "SG", 40, .inactive)
        let inactive = tracker.assessment(at: date.addingTimeInterval(45))
        #expect(inactive.kind == nil && inactive.points == 0 && inactive.minimumTotal == 0)
        #expect(inactive.crossRegionCount == 0)
        #expect(tracker.history.lastObserved?.country == "SG")
        #expect(tracker.history.lastExposedByFamily == nil)
        accept(&tracker, "203.0.113.3", "SG", 60, .active)
        #expect(tracker.assessment(at: date.addingTimeInterval(65)).crossRegionCount == 0)
        #expect(tracker.history.lastExposedByFamily?["ipv4"]?.country == "SG")
    }

    @Test func offlineRoundTripReturningToTheSameExposedCountryDoesNotCreateRisk() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "TR", 0, .active))
        tracker.usageBoundaryChanged()
        accept(&tracker, "203.0.113.2", "CN", 20, .inactive)
        accept(&tracker, "203.0.113.3", "TR", 40, .inactive)
        tracker.usageBoundaryChanged()
        accept(&tracker, "203.0.113.3", "TR", 60, .active)
        #expect(tracker.assessment(at: date.addingTimeInterval(65)).minimumTotal == 0)
        #expect(tracker.assessment(at: date.addingTimeInterval(65)).crossRegionCount == 0)
    }

    @Test func resumedUseComparesExposedEndpointsWithoutCountingOfflineIntermediateCountries() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US", 0, .active))
        accept(&tracker, "203.0.113.2", "CN", 20, .inactive)
        accept(&tracker, "203.0.113.3", "SG", 40, .inactive)
        accept(&tracker, "203.0.113.4", "TR", 60, .active)
        let result = tracker.assessment(at: date.addingTimeInterval(65))
        #expect(result.crossRegionCount == 1)
        #expect(result.minimumTotal == 50)
        #expect(result.change?.previous.country == "US")
        #expect(result.change?.current.country == "TR")
    }

    @Test func quittingCannotEraseGenuineExposedRiskAndInactiveMovesCannotEscalateIt() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US", 0, .active))
        accept(&tracker, "203.0.113.2", "TR", 20, .active)
        #expect(tracker.assessment(at: date.addingTimeInterval(25)).minimumTotal == 50)
        tracker.usageBoundaryChanged()
        accept(&tracker, "203.0.113.3", "US", 40, .inactive)
        accept(&tracker, "203.0.113.4", "CN", 60, .inactive)
        let result = tracker.assessment(at: date.addingTimeInterval(65))
        #expect(result.minimumTotal == 50)
        #expect(result.crossRegionCount == 1)
        #expect(result.kind == .anomalous)
    }

    @Test func unknownActivityIsNotInferredAsActiveOrAsAConfirmedInactiveExemption() {
        var tracker = GuardNetworkTracker()
        tracker.observe(exit("203.0.113.1", "US", 0, .unknown))
        accept(&tracker, "203.0.113.2", "TR", 20, .unknown)
        #expect(tracker.assessment(at: date.addingTimeInterval(25)).crossRegionCount == 0)
        #expect(tracker.history.lastObserved?.desktopActivity == .unknown)
        #expect(tracker.history.lastExposedByFamily == nil)
    }

    @Test func legacyEventsAndScoresAreRetainedWithoutCreatingUnprovenNewFloors() {
        let previous = exit("203.0.113.1", "CN", 0, .unknown)
        let current = exit("203.0.113.2", "TR", 20, .unknown)
        let event = GuardGeoTransition(id: UUID(), previous: previous, current: current, anomalous: true)
        let history = GuardNetworkHistory(lastLaunch: current, geographicTransitions: [event],
            incident: .init(transition: event, extreme: true, roundTrip: true, stableSeconds: 0))
        var tracker = GuardNetworkTracker(history: history)
        tracker.observe(exit("203.0.113.2", "TR", 40, .inactive))
        let result = tracker.assessment(at: date.addingTimeInterval(40))
        #expect(result.minimumTotal == 0 && result.crossRegionCount == 0)
        #expect(tracker.history.geographicTransitions == [event])
        #expect(tracker.history.incident?.transition == event)
        #expect(tracker.hasLegacyExposureHistory)
    }

    @MainActor @Test func processPresenceIsCheckedWithoutTreatingAnInstallationOrUntrustedNameAsExecution() {
        let home = URL(fileURLWithPath: "/tmp/guard-user")
        let roots = ["/Applications/Claude.app/"]
        #expect(GuardDesktopActivityReader.classify(desktopRunning: false, processes: [], appPaths: roots, home: home) == .inactive)
        #expect(GuardDesktopActivityReader.classify(desktopRunning: false, processes: nil, appPaths: roots, home: home) == .unknown)
        let fake = GuardRuntimeProcess(pid: 1, parent: 0, path: "/tmp/claude")
        #expect(GuardDesktopActivityReader.classify(desktopRunning: false, processes: [fake], appPaths: roots, home: home) == .inactive)
        let cowork = GuardRuntimeProcess(pid: 2, parent: 1, path: "/Applications/Claude.app/Contents/Resources/cowork")
        #expect(GuardDesktopActivityReader.classify(desktopRunning: false, processes: [cowork], appPaths: roots, home: home) == .active)
        let residual = GuardRuntimeProcess(pid: 3, parent: 1, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper")
        #expect(GuardDesktopActivityReader.classify(desktopRunning: false, processes: [residual], appPaths: roots, home: home) == .unknown)
        #expect(GuardDesktopActivityReader.classify(desktopRunning: true, processes: nil, appPaths: roots, home: home) == .active)
        #expect(GuardDesktopActivityReader.sample(start: .inactive, end: .inactive, lifecycleChanged: true) == .unknown)
        #expect(GuardDesktopActivityReader.sample(start: .inactive, end: .active, lifecycleChanged: false) == .unknown)
        #expect(GuardDesktopActivityReader.sample(start: .inactive, end: .inactive, lifecycleChanged: false) == .inactive)
    }

    @MainActor @Test func inactiveSampleOverridesAStaleRunningUIAndIsLoggedWithExemptionEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-exemption-\(UUID().uuidString)")
        let service = EnvironmentGuardService(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            historyStore: .init(url: folder.appendingPathComponent("history.json")), activityProvider: { .inactive })
        service.loadDesignPreview(running: true)
        #expect(service.snapshot.client?.pid == Int32.max)
        #expect(service.applyNetworkObservation(.init(countryCode: "US", fetchedAt: .now, ip: "203.0.113.1", timeZone: "America/Los_Angeles"), activity: .inactive))
        #expect(service.applyNetworkObservation(.init(countryCode: "TR", fetchedAt: .now, ip: "203.0.113.2", timeZone: "Europe/Istanbul"), verification: .verified, activity: .inactive))
        #expect(service.snapshot.client?.pid == Int32.max)
        let page = try await service.loadExitHistory()
        #expect(service.snapshot.desktopActivity == .inactive)
        #expect(service.snapshot.networkBehavior.minimumTotal == 0)
        #expect(page.entries.first?.exit.desktopActivity == .inactive)
        #expect(page.entries.first?.risk?.desktopActivity == .inactive)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
