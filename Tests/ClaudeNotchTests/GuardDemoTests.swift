#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import ClaudeNotch

@Suite struct GuardDemoTests {
    @MainActor private func service() -> (EnvironmentGuardService, URL) {
        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("guard-demo-test-" + id).appendingPathComponent("history.json")
        return (EnvironmentGuardService(defaults: UserDefaults(suiteName: "guard-demo-test-" + id)!, historyStore: .init(url: file)), file)
    }

    @MainActor @Test func scenariosUseSyntheticMemoryOnlyAndExerciseTheRealRiskModel() {
        let (guardService, file) = service()
        for scenario in GuardDemoScenario.allCases {
            guardService.loadGuardDemo(scenario)
            #expect(guardService.isDesignPreview)
            switch scenario {
            case .repeated, .roundTrip, .longIPv6: #expect(guardService.configuredRisk.total == 80)
            case .anomalous: #expect(guardService.configuredRisk.total == 50)
            case .unverified: #expect(guardService.configuredRisk.total == nil)
            case .dualStack: #expect(guardService.configuredRisk.total == 30)
            case .sameCountry, .clashRule, .clashUnknown, .connectionCombined:
                #expect(guardService.configuredRisk.total == 10)
                #expect(guardService.hasNetworkWarning)
            case .inactive, .connectionHealthy:
                #expect(guardService.configuredRisk.total == 10)
                #expect(!guardService.hasNetworkWarning)
            }
            guardService.ignoreNetworkRisk()
            #expect(!guardService.hasNetworkWarning)
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    @MainActor @Test func previewCannotStartRestartOrQuitARealClaudeOrRefreshProviders() async {
        let (guardService, file) = service()
        let model = AppModel(environmentGuard: guardService)
        model.loadGuardDemo(.repeated)
        model.start()
        model.refreshNow()
        model.togglePause()
        model.selectProvider(.codex)
        model.isExpanded = false
        model.isExpanded = true
        #expect(!guardService.isChecking && !guardService.isCheckingNetwork)
        #expect(await guardService.launchClaude() == false)
        #expect(await guardService.restartWithProfile() == false)
        #expect(guardService.snapshot.client?.pid == Int32.max)
        await guardService.closeClaudeForNetworkRisk()
        #expect(guardService.snapshot.client?.pid == nil)
        #expect(guardService.snapshot.networkBehavior.minimumTotal == 80)
        #expect(!guardService.isClosingClaude)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @MainActor @Test func longIPv6WarningNaturallyGrows() {
        let (guardService, _) = service()
        func height(_ scenario: GuardDemoScenario) -> CGFloat {
            guardService.loadGuardDemo(scenario)
            return NSHostingView(rootView: NetworkWarningView(service: guardService, language: .chinese,
                animate: false, measuredHeight: { _ in }).frame(width: 672)).fittingSize.height
        }
        let short = height(.repeated), long = height(.longIPv6)
        #expect(long >= short)
        #expect(long < 200)
    }

    @MainActor @Test func connectionDemoCloseAndRecoveryRemainSynthetic() async {
        let (guardService, file) = service()
        let model = AppModel(environmentGuard: guardService)
        model.loadGuardDemo(.connectionCombined)
        #expect(guardService.connectionMonitor.visibleIssues.count == 2)
        #expect(model.recentSessions.count == 3 && model.claudeDailySeries.count == 7)
        if let screen = NSScreen.main {
            let presentation = IslandPresentationState(screen: screen)
            presentation.notchWidth = 160; presentation.topInset = 32; presentation.isExpanded = true
            let host = NSHostingView(rootView: IslandView(model: model, presentation: presentation))
            let size = NSSize(width: 720, height: model.expandedDropHeight + presentation.topInset)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            host.frame.size.height = model.expandedDropHeight + presentation.topInset
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-full-warning-release.png"))
                }
            }
        }
        guardService.recheckConnection()
        #expect(!guardService.isCheckingConnection && !guardService.isCheckingNetwork)
        await guardService.closeClaudeForNetworkRisk()
        #expect(guardService.connectionMonitor.visibleIssues.isEmpty)
        guardService.loadGuardDemo(.connectionHealthy)
        #expect(!guardService.hasNetworkWarning)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
}
#endif
