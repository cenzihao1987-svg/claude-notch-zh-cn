import AppKit
import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardRiskBannerTests {
    private let profile = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
    private var matching: GuardProcessConfiguration {
        .init(language: "en-US", appleLanguages: "(en-US)", locale: "en_US", timeZone: "America/Los_Angeles")
    }
    private func client(pid: Int32? = 42, process: GuardProcessConfiguration? = nil, instances: Int = 1) -> GuardClient {
        .init(path: "/Applications/Claude.app", version: "1", pid: pid, launchedAt: pid == nil ? nil : Date(timeIntervalSince1970: 1000),
              process: process, runningInstanceCount: pid == nil ? 0 : instances)
    }
    private func item(_ id: String, _ kind: GuardRiskItem.Kind = .exitUnknown) -> GuardRiskItem { .init(id: id, kind: kind) }

    @Test func protectionStateCoversEveryLaunchPath() {
        var off = profile; off.enabled = false
        var incomplete = profile; incomplete.timeZoneIdentifier = ""
        let receipt = LaunchReceipt(pid: 42, launchedAt: Date(timeIntervalSince1970: 1000), appPath: "/Applications/Claude.app", profile: profile)
        let other = GuardProcessConfiguration(language: "en-US", appleLanguages: "(en-US)", locale: "en_TR", timeZone: "Europe/Istanbul")
        #expect(GuardProtectionState.evaluate(profile: profile, client: nil, receipt: nil) == .unknown)
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(pid: nil), receipt: nil) == .ready)
        #expect(GuardProtectionState.evaluate(profile: off, client: client(pid: nil), receipt: nil) == .off)
        #expect(GuardProtectionState.evaluate(profile: off, client: client(), receipt: nil) == .profileOff)
        #expect(GuardProtectionState.evaluate(profile: incomplete, client: client(process: GuardProcessConfiguration()), receipt: nil) == .unknown)
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(process: matching, instances: 2), receipt: nil) == .notFromNotch(instances: 2))
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(process: nil), receipt: nil) == .unknown)
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(process: matching), receipt: nil) == .protected)
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(process: other), receipt: receipt) == .profileChanged)
        #expect(GuardProtectionState.evaluate(profile: profile, client: client(process: GuardProcessConfiguration()), receipt: nil) == .notFromNotch(instances: 1))
        #expect(!GuardProtectionState.protected.isUnprotectedRun && GuardProtectionState.profileOff.isUnprotectedRun)
    }

    @Test func resolvedRowsStayThreeSecondsAndTheLastFixTurnsGreen() {
        var state = GuardRiskBannerState()
        let start = Date(timeIntervalSince1970: 0)
        state.reconcile([item("a"), item("b")], resolvable: { _ in true }, now: start)
        #expect(state.openCount == 2 && !state.showsResolvedRows)
        state.reconcile([item("b")], resolvable: { _ in true }, now: start.addingTimeInterval(1))
        #expect(state.openCount == 1 && state.showsResolvedRows)
        #expect(state.nextDeadline == start.addingTimeInterval(4))
        state.reconcile([item("b")], resolvable: { _ in true }, now: start.addingTimeInterval(3.9))
        #expect(state.rows.count == 2)
        state.reconcile([item("b")], resolvable: { _ in true }, now: start.addingTimeInterval(4.1))
        #expect(state.rows.map(\.id) == ["b"])
        state.reconcile([], resolvable: { _ in true }, now: start.addingTimeInterval(5))
        #expect(state.rows.isEmpty && state.allClearAt == start.addingTimeInterval(5))
        #expect(state.resolvedItems.map(\.id) == ["a", "b"])
        state.reconcile([], resolvable: { _ in true }, now: start.addingTimeInterval(9.1))
        #expect(state.isEmpty && state.resolvedItems.isEmpty)
    }

    @Test func ignoringOrStoppedMonitoringNeverCountsAsHandled() {
        var state = GuardRiskBannerState()
        let now = Date(timeIntervalSince1970: 0)
        state.reconcile([item("a")], resolvable: { _ in true }, now: now)
        state.ignore("a")
        state.reconcile([item("a")], resolvable: { _ in true }, now: now)
        #expect(state.isEmpty)
        state.reconcile([], resolvable: { _ in true }, now: now)
        #expect(state.isEmpty && state.allClearAt == nil)
        state.reconcile([item("a")], resolvable: { _ in true }, now: now)
        #expect(state.openCount == 1)
        state.reconcile([], resolvable: { _ in false }, now: now)
        #expect(state.isEmpty && state.allClearAt == nil)
    }

    @Test func checkingRowsWaitForTheirDeadlineAndReturnToPending() {
        var state = GuardRiskBannerState()
        let now = Date(timeIntervalSince1970: 0)
        state.reconcile([item("p", .protection(.notFromNotch(instances: 1)))], resolvable: { _ in false }, now: now)
        state.markChecking("p", until: now.addingTimeInterval(90))
        // Claude quits during the protected restart: the row waits instead of disappearing.
        state.reconcile([], resolvable: { _ in false }, now: now.addingTimeInterval(5))
        #expect(state.rows.first?.phase == .checking(until: now.addingTimeInterval(90)))
        state.reconcile([], resolvable: { _ in true }, now: now.addingTimeInterval(8))
        #expect(state.allClearAt == now.addingTimeInterval(8))

        var timedOut = GuardRiskBannerState()
        timedOut.reconcile([item("c")], resolvable: { _ in false }, now: now)
        timedOut.markChecking("c", until: now.addingTimeInterval(60))
        timedOut.reconcile([item("c")], resolvable: { _ in false }, now: now.addingTimeInterval(61))
        #expect(timedOut.rows.first?.phase == .pending)
        timedOut.markChecking("c", until: now.addingTimeInterval(120))
        timedOut.settle("c", isCurrent: true)
        #expect(timedOut.rows.first?.phase == .pending)
    }

    @Test func monitorIgnoresOneIssueAndKeepsTheOthers() {
        var monitor = GuardConnectionMonitor(baselines: ["ipv4": GuardExit(.init(countryCode: "US", fetchedAt: .now, ip: "203.0.113.1"))!])
        monitor.setActive(true)
        monitor.observeClash(.rule, at: .now)
        monitor.failedExit()
        #expect(monitor.visibleIssues.count == 2)
        monitor.acknowledge("clash-rule")
        #expect(monitor.visibleIssues.map(\.id) == ["exit-unknown"])
        monitor.observeClash(.global, at: .now)
        monitor.observeClash(.rule, at: .now)
        #expect(monitor.visibleIssues.count == 2)
    }

    @MainActor private func demoService() -> EnvironmentGuardService {
        let id = UUID().uuidString
        return EnvironmentGuardService(defaults: UserDefaults(suiteName: "risk-banner-" + id)!,
            historyStore: .init(url: FileManager.default.temporaryDirectory.appendingPathComponent("risk-banner-" + id).appendingPathComponent("history.json")))
    }

    #if DEBUG
    @MainActor @Test func unprotectedRunExpandsOncePerInstanceAndIgnoreHidesOnlyIt() async {
        let service = demoService()
        service.loadGuardDemo(.unprotectedCombined)
        let generation = service.networkNoticeGeneration
        service.reconcileRiskBanner()
        #expect(service.riskItems.map(\.action) == [.relaunch, .openClash])
        #expect(service.networkNoticeGeneration == generation + 1)
        service.reconcileRiskBanner()
        #expect(service.networkNoticeGeneration == generation + 1)
        let protection = service.riskItems[0].id
        service.ignoreRiskItem(protection)
        #expect(service.riskItems.map(\.action) == [.openClash])
        #expect(service.riskBanner.rows.map(\.id) == [service.riskItems[0].id])
        #expect(service.protectionState.isUnprotectedRun)
    }

    @MainActor @Test func previewActionsResolveRowsWithoutTouchingRealApps() async throws {
        let service = demoService()
        service.loadGuardDemo(.unprotectedCombined)
        service.reconcileRiskBanner()
        let protection = service.riskItems[0].id
        #expect(await service.relaunchWithProtection(itemID: protection))
        service.reconcileRiskBanner()
        #expect(service.protectionState == .protected)
        #expect(service.riskBanner.rows.first { $0.id == protection }.map { !$0.isOpen } == true)
        service.applyClashObservation(.global, activity: .active)
        service.reconcileRiskBanner()
        #expect(service.riskBanner.openCount == 0 && service.riskBanner.allClearAt != nil)
    }

    @MainActor @Test func welcomeShowsOnFirstRunUntilAnswered() async {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "welcome-" + id)!
        let store = GuardHistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("welcome-" + id).appendingPathComponent("history.json"))
        let first = EnvironmentGuardService(defaults: defaults, historyStore: store)
        #expect(first.showsWelcome)
        first.dismissWelcome()
        #expect(!first.showsWelcome)
        #expect(!EnvironmentGuardService(defaults: defaults, historyStore: store).showsWelcome)

        let returning = UserDefaults(suiteName: "welcome-returning-" + id)!
        let receipt = LaunchReceipt(pid: 1, launchedAt: .now, appPath: "/Applications/Claude.app", profile: profile)
        returning.set(try? JSONEncoder().encode(receipt), forKey: EnvironmentGuardService.receiptKey)
        #expect(!EnvironmentGuardService(defaults: returning, historyStore: store).showsWelcome)

        let demo = demoService()
        demo.loadGuardDemo(.welcome)
        #expect(demo.showsWelcome && !demo.profile.enabled && demo.riskItems.isEmpty)
        #expect(await demo.enableProtectionAndLaunch())
        #expect(!demo.showsWelcome)
    }
    #endif

    /// Real launches stop before any file or app is touched: a cancelled network check, then a
    /// missing exit location. The successful path is covered by the preview test above.
    @MainActor @Test func welcomeLaunchTurnsProfileOnAndKeepsCardWhenCancelledOrFailed() async throws {
        let harness = GuardConnectionServiceTests.Harness()
        harness.allow = false
        harness.samples = [.init(exit: nil, clash: .rule)]
        let service = try harness.service(profile: false)
        #expect(service.showsWelcome)
        #expect(!(await service.enableProtectionAndLaunch()))
        #expect(service.profile.enabled && service.showsWelcome && !service.operationFailed && harness.opens == 0)
        harness.allow = true
        harness.samples = [.init(exit: GuardExit(.init(countryCode: "US", fetchedAt: .now, ip: "203.0.113.9")), clash: .global)]
        #expect(!(await service.enableProtectionAndLaunch()))
        #expect(service.operationFailed && service.showsWelcome && harness.opens == 0 && harness.quits == 0)
        service.stop()
    }
}
