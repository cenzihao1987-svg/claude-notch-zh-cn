import AppKit
import SwiftUI
import Testing
@testable import ClaudeNotch

@Suite struct NetworkWarningLayoutTests {
    @MainActor @Test func warningMeasuresItsContentAndDismissalRetainsRisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-layout-\(UUID().uuidString)")
        let service = EnvironmentGuardService(defaults: UserDefaults(suiteName: "guard-layout-\(UUID().uuidString)")!,
            historyStore: .init(url: directory.appendingPathComponent("history.json")))
        service.loadDesignPreview(running: true, networkWarning: true)
        #expect(service.hasNetworkWarning)
        service.reconcileRiskBanner()
        #expect(service.riskBanner.rows.map(\.item.action) == [.details])
        let host = NSHostingView(rootView: NetworkWarningView(service: service, language: .chinese, animate: false,
            measuredHeight: { _ in }).frame(width: 672))
        let size = host.fittingSize
        #expect(size.width == 672)
        #expect(size.height > 60 && size.height < 180)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-v111-warning.png"))
            }
        }
        let before = service.configuredRisk
        service.ignoreNetworkRisk()
        #expect(!service.hasNetworkWarning)
        #expect(service.configuredRisk == before)
        #expect(service.snapshot.networkBehavior.minimumTotal == 80)
    }
}
