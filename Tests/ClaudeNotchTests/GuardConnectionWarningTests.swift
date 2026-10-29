import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClaudeNotch

@Suite struct GuardConnectionWarningTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func exit(_ ip: String, _ seconds: Double = 0, country: String = "US") -> GuardExit {
        GuardExit(.init(countryCode: country, fetchedAt: date.addingTimeInterval(seconds), ip: ip), activity: .active)!
    }

    @Test func firstUseAndIndependentAddressFamiliesEstablishBaselines() {
        var monitor = GuardConnectionMonitor()
        monitor.setActive(true); monitor.observeClash(.global, at: date)
        monitor.observe(exit("203.0.113.1")); monitor.observe(exit("2001:db8::1", 1))
        monitor.observe(exit("203.0.113.1", 2)); monitor.observe(exit("2001:db8::1", 3))
        #expect(monitor.issues.isEmpty)
        #expect(monitor.baselines.count == 2)
    }

    @Test func sameCountryChangeRequiresRepeatAndDoesNotChangeGeographicScore() {
        var monitor = GuardConnectionMonitor(); var geographic = GuardNetworkTracker()
        monitor.setActive(true)
        for e in [exit("203.0.113.1"), exit("203.0.113.2", 10), exit("203.0.113.2", 12)] {
            monitor.observe(e); geographic.observe(e)
        }
        #expect(monitor.issues.isEmpty)
        let accepted = exit("203.0.113.2", 15)
        monitor.observe(accepted); geographic.observe(accepted)
        #expect(monitor.issues.map(\.kind) == [.ipChanged])
        #expect(monitor.takeNewNotice().count == 1)
        #expect(monitor.takeNewNotice().isEmpty)
        #expect(geographic.assessment(at: accepted.observedAt).points == 0)
    }

    @Test func crossCountryStillWarnsAndInterruptedRepeatIsNotAccepted() {
        var monitor = GuardConnectionMonitor(); monitor.setActive(true)
        monitor.observe(exit("203.0.113.1"))
        monitor.observe(exit("203.0.113.2", 5, country: "JP"))
        monitor.failedExit()
        monitor.observe(exit("203.0.113.2", 10, country: "JP"))
        #expect(monitor.issues.isEmpty)
        monitor.observe(exit("203.0.113.2", 15, country: "JP"))
        #expect(monitor.issues.first?.change?.countryChanged == true)
    }

    @Test func inactivityPreservesUsedExitAndNextSessionWarns() {
        var monitor = GuardConnectionMonitor(); monitor.setActive(true)
        monitor.observe(exit("203.0.113.1")); monitor.setActive(false)
        monitor.observe(exit("203.0.113.2", 10)); monitor.observe(exit("203.0.113.3", 20))
        #expect(monitor.baselines["ipv4"]?.ip == "203.0.113.1")
        #expect(monitor.issues.isEmpty)
        monitor.setActive(true)
        monitor.observe(exit("203.0.113.3", 30)); monitor.observe(exit("203.0.113.3", 35))
        #expect(monitor.issues.first?.change?.previous.ip == "203.0.113.1")
        #expect(monitor.issues.first?.change?.current.ip == "203.0.113.3")
    }

    @Test func modeRecoveryRearmsNotificationAndDismissDoesNotEraseBaseline() {
        var monitor = GuardConnectionMonitor(); monitor.setActive(true)
        monitor.observe(exit("203.0.113.1"))
        monitor.observeClash(.rule, at: date)
        #expect(monitor.takeNewNotice().count == 1)
        monitor.acknowledge()
        #expect(monitor.visibleIssues.isEmpty)
        #expect(monitor.baselines.count == 1)
        monitor.observeClash(.global, at: date)
        monitor.observeClash(.rule, at: date)
        #expect(monitor.takeNewNotice().count == 1)
        monitor.setActive(false)
        #expect(monitor.visibleIssues.isEmpty)
    }

    @Test func unknownExitIsDistinctAndClearsAfterSuccessfulSample() {
        var monitor = GuardConnectionMonitor(); monitor.setActive(true)
        monitor.failedExit(); monitor.observeClash(.unknown, at: date)
        #expect(monitor.issues.count == 2)
        monitor.observe(exit("203.0.113.1")); monitor.observeClash(.global, at: date)
        #expect(monitor.issues.isEmpty)
    }

    @Test func modeParserUsesRuntimeResponseAndEndpointParserIgnoresSavedMode() throws {
        for (mode, expected) in [("global", GuardClashState.global), ("rule", .rule), ("direct", .direct), ("bogus", .unknown)] {
            #expect(GuardClashReader.decode(Data("{\"mode\":\"\(mode)\",\"tun\":{\"enable\":true}}".utf8)) == expected)
        }
        #expect(GuardClashReader.decode(Data("{\"mode\":\"global\"}".utf8), status: 401) == .unknown)
        #expect(GuardClashReader.decode(Data("bad".utf8)) == .unknown)
        #expect(GuardClashReader.endpoint(Data("mode: global\nenable_tun_mode: true".utf8)) == nil)
        let endpoint = try #require(GuardClashReader.endpoint(Data("mode: global\nexternal-controller: '0.0.0.0:9090'\nexternal-controller-unix: '/tmp/test.sock'\nsecret: 'dummy-test'".utf8)))
        #expect(endpoint.controller?.host == "127.0.0.1")
        #expect(endpoint.socket == "/tmp/test.sock")
        #expect(GuardClashReader.endpoint(Data("external-controller: 192.0.2.1:9090".utf8)) == nil)
    }

    @MainActor @Test func gateCancelsBeforeAnyLaunchOrQuit() async throws {
        var events: [String] = []
        let result = try await GuardLaunchNetworkGate.authorize(baselines: [:], sample: {
            events.append("sample"); return .init(exit: exit("203.0.113.1"), clash: .rule)
        }, confirm: { _, _ in events.append("cancel"); return false }, wait: {})
        if result != nil { events.append("quit-or-launch") }
        #expect(result == nil)
        #expect(events == ["sample", "cancel"])
    }

    @MainActor @Test func gateChecksAgainAfterContinueAndRepromptsForNewState() async throws {
        let modes: [GuardClashState] = [.rule, .direct]
        var reads = 0; var prompts = 0
        let result = try await GuardLaunchNetworkGate.authorize(baselines: [:], sample: {
            defer { reads += 1 }; return .init(exit: exit("203.0.113.1"), clash: modes[min(reads, 1)])
        }, confirm: { _, _ in prompts += 1; return prompts == 1 }, wait: {})
        #expect(result == nil)
        #expect(reads == 2 && prompts == 2)
    }

    @MainActor @Test func gateAllowsExplicitUnknownAndNormalFirstUseWithoutWarning() async throws {
        var prompts = 0
        let unknown = try await GuardLaunchNetworkGate.authorize(baselines: [:], sample: { .init(exit: nil, clash: .unknown) },
            confirm: { _, issues in prompts += 1; #expect(issues.count == 2); return true }, wait: {})
        #expect(unknown != nil && prompts == 1)
        let good = try await GuardLaunchNetworkGate.authorize(baselines: [:], sample: { .init(exit: exit("203.0.113.1"), clash: .global) },
            confirm: { _, _ in prompts += 1; return false }, wait: {})
        #expect(good != nil && prompts == 1)
    }

    @MainActor @Test func changedExitHasTwoSamplesAndApprovalCanBeRevalidated() async throws {
        var waits = 0; var reads = 0; var prompts = 0
        let sample = GuardLaunchNetworkSample(exit: exit("203.0.113.2", 10), clash: .global)
        let approved = try await GuardLaunchNetworkGate.authorize(baselines: ["ipv4": exit("203.0.113.1")], sample: {
            reads += 1; return sample
        }, confirm: { _, _ in prompts += 1; return true }, wait: { waits += 1 })
        #expect(approved != nil && reads == 3 && waits == 1 && prompts == 1)
        _ = try await GuardLaunchNetworkGate.authorize(baselines: ["ipv4": exit("203.0.113.1")], approved: approved?.fingerprint,
            sample: { sample }, confirm: { _, _ in prompts += 1; return false }, wait: { waits += 1 })
        #expect(prompts == 1 && waits == 1)
    }

    @MainActor @Test func unstableExitDoesNotLaunch() async {
        var reads = 0; var prompts = 0
        do {
            _ = try await GuardLaunchNetworkGate.authorize(baselines: ["ipv4": exit("203.0.113.1")], sample: {
                reads += 1; return .init(exit: exit(reads == 1 ? "203.0.113.2" : "203.0.113.3"), clash: .global)
            }, confirm: { _, _ in prompts += 1; return true }, wait: {})
            Issue.record("Unstable route must not be authorized")
        } catch { #expect(error is GuardLaunchNetworkError) }
        #expect(prompts == 0)
    }

    @Test func oldHistoryDecodesWithoutNewField() throws {
        let history = try JSONDecoder().decode(GuardNetworkHistory.self, from: Data("{}".utf8))
        #expect(history.connectionBaselines == nil)
        var tracker = GuardNetworkTracker(history: history)
        tracker.setConnectionBaselines(["ipv4": exit("203.0.113.1")])
        let restored = try JSONDecoder().decode(GuardNetworkHistory.self, from: JSONEncoder().encode(tracker.history))
        #expect(restored.connectionBaselines?["ipv4"]?.ip == "203.0.113.1")
    }
}

@MainActor @Suite struct GuardConnectionServiceTests {
    @MainActor final class Harness {
        var samples: [GuardLaunchNetworkSample] = [.init(exit: nil, clash: .unknown)]
        var reads = 0; var confirms = 0; var opens = 0; var quits = 0
        var running = false; var allow = false; var notices = 0
        var answers: [Bool] = []
        func service(profile: Bool = false) throws -> EnvironmentGuardService {
            let defaults = UserDefaults(suiteName: "connection-tests-\(UUID().uuidString)")!
            let value = GuardProfile(enabled: profile, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
            defaults.set(try JSONEncoder().encode(value), forKey: EnvironmentGuardService.profileKey)
            let store = GuardHistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("connection-test-\(UUID().uuidString)/history.json"))
            return EnvironmentGuardService(defaults: defaults, historyStore: store, activityProvider: { .inactive },
                clashProvider: { .global }, launchNetworkSampler: {
                    defer { self.reads += 1 }; return self.samples[min(self.reads, self.samples.count - 1)]
                }, launchConfirmation: { _, _ in
                    self.confirms += 1
                    return self.answers.isEmpty ? self.allow : self.answers[min(self.confirms - 1, self.answers.count - 1)]
                },
                notificationSender: { _ in self.notices += 1 },
                launchActions: .init(installedURL: { _ in URL(fileURLWithPath: "/Applications/MockClaude.app") },
                    running: { self.running ? [.current] : [] }, quit: { self.quits += 1; self.running = false; return true },
                    open: { _, _ in self.opens += 1; self.running = true; return .current }))
        }
    }

    @Test func cancelColdLaunchAndHandoffDoNotLaunchOrSetFailure() async throws {
        let harness = Harness(); let service = try harness.service()
        #expect(!(await service.launchClaude()))
        #expect(!service.operationFailed)
        #expect(!(await service.prepareForHandoff()))
        #expect(harness.opens == 0 && harness.quits == 0 && harness.confirms == 2)
        service.stop()
    }

    @Test(arguments: [false, true]) func restartCancellationPrecedesQuit(profile: Bool) async throws {
        let harness = Harness(); harness.running = true
        let service = try harness.service(profile: profile)
        let result = profile ? await service.restartWithProfile() : await service.restartWithoutProfile()
        #expect(!result && !service.operationFailed)
        #expect(harness.running && harness.quits == 0 && harness.opens == 0)
        service.stop()
    }

    @Test func confirmedLaunchUsesOnlyFakeOpenerAndPersistsUsedBaseline() async throws {
        let harness = Harness(); harness.allow = true
        let exit = GuardExit(.init(countryCode: "US", fetchedAt: .now, ip: "203.0.113.8"))!
        harness.samples = [.init(exit: exit, clash: .rule)]
        let service = try harness.service()
        #expect(await service.launchClaude())
        #expect(harness.opens == 1 && harness.confirms == 1)
        #expect(service.networkTracker.history.connectionBaselines?["ipv4"]?.ip == "203.0.113.8")
        #expect(!service.operationFailed)
        let generation = service.networkNoticeGeneration
        service.applyClashObservation(.rule, activity: .active)
        #expect(service.networkNoticeGeneration == generation)
        #expect(service.hasNetworkWarning)
        service.stop()
    }

    @Test func restartAndAlreadyRunningHandoffRespectGate() async throws {
        let harness = Harness(); harness.allow = true; harness.running = true
        let service = try harness.service()
        #expect(await service.restartWithoutProfile())
        #expect(harness.quits == 1 && harness.opens == 1 && harness.confirms == 1)
        harness.allow = false
        #expect(!(await service.prepareForHandoff()))
        #expect(harness.opens == 1 && harness.quits == 1 && !service.operationFailed)
        service.stop()
    }

    @Test func changedStateDuringConfirmationRepromptsBeforeOpening() async throws {
        let harness = Harness(); harness.allow = true
        harness.samples = [.init(exit: nil, clash: .rule), .init(exit: nil, clash: .direct), .init(exit: nil, clash: .global)]
        let service = try harness.service()
        #expect(await service.launchClaude())
        #expect(harness.confirms == 3 && harness.opens == 1)
        service.stop()
    }

    @Test func secondConfirmationCancellationDoesNotLaunch() async throws {
        let harness = Harness(); harness.answers = [true, false]
        harness.samples = [.init(exit: nil, clash: .rule), .init(exit: nil, clash: .direct)]
        let service = try harness.service()
        #expect(!(await service.launchClaude()))
        #expect(harness.confirms == 2 && harness.opens == 0 && !service.operationFailed)
        service.stop()
    }

    @Test func runtimeNoticeDeduplicatesAndNotificationDenialDoesNotHideWarning() async throws {
        let harness = Harness(); let service = try harness.service()
        service.applyClashObservation(.rule, activity: .active)
        let generation = service.networkNoticeGeneration
        for _ in 0..<5 { await Task.yield() }
        #expect(harness.notices == 1)
        service.applyClashObservation(.rule, activity: .active)
        #expect(service.hasNetworkWarning && service.networkNoticeGeneration == generation)
        service.ignoreNetworkRisk()
        #expect(!service.hasNetworkWarning)
        service.applyClashObservation(.global, activity: .active)
        service.applyClashObservation(.direct, activity: .active)
        #expect(service.hasNetworkWarning && service.networkNoticeGeneration > generation)
        service.applyClashObservation(.global, activity: .active)
        #expect(!service.hasNetworkWarning)
        service.stop()
    }

    @Test func combinedWarningFitsNotchAndSameCountryRiskRemainsZero() throws {
        let harness = Harness(); let service = try harness.service()
        service.applyClashObservation(.rule, activity: .active)
        let base = Date.now.addingTimeInterval(-30)
        for (ip, time) in [("203.0.113.1", 0.0), ("203.0.113.2", 10.0), ("203.0.113.2", 15.0)] {
            #expect(service.applyNetworkObservation(.init(countryCode: "US", fetchedAt: base.addingTimeInterval(time), ip: ip), activity: .active))
        }
        #expect(service.connectionMonitor.visibleIssues.count == 2)
        #expect(service.snapshot.networkBehavior.points == 0)
        service.reconcileRiskBanner()
        #expect(service.riskBanner.rows.map(\.item.action) == [.openClash, .confirmExit])
        let host = NSHostingView(rootView: NetworkWarningView(service: service, language: .chinese, animate: false, measuredHeight: { _ in }).frame(width: 672))
        #expect(host.fittingSize.width == 672)
        #expect(host.fittingSize.height > 75 && host.fittingSize.height < 240)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("claude-connection-warning.png"))
            }
        }
        let risk = service.configuredRisk
        service.ignoreNetworkRisk()
        #expect(!service.hasNetworkWarning && service.configuredRisk == risk)
        service.stop()
    }

    @Test func handoffCancellationNeverEntersFallbackOrCopiesInstruction() async {
        var opened = 0; var fallback = 0
        let result = await HandoffCoordinator.deliverClaude(packetPath: "fixture", instruction: "fixture",
            authorize: { false }, failure: { nil }, open: { opened += 1; return false },
            fallback: { fallback += 1; return true })
        #expect(result == .cancelled)
        #expect(opened == 0 && fallback == 0)
    }

    @Test func handoffLaunchFailureStopsBeforeFallbackButDeepLinkFailureCanFallback() async {
        var fallback = 0
        let failed = await HandoffCoordinator.deliverClaude(packetPath: "fixture", instruction: "fixture",
            authorize: { false }, failure: { "test launch error" }, open: { false },
            fallback: { fallback += 1; return true })
        #expect(failed == .failed(packetPath: "fixture", instruction: nil, reason: "test launch error"))
        #expect(fallback == 0)
        let degraded = await HandoffCoordinator.deliverClaude(packetPath: "fixture", instruction: "fixture",
            authorize: { true }, failure: { nil }, open: { false },
            fallback: { fallback += 1; return true })
        if case .fallback = degraded {} else { Issue.record("Authorized deep-link failure should retain manual fallback") }
        #expect(fallback == 1)
    }
}
