import AppKit
import SwiftUI

@MainActor
final class NetworkHistoryWindow: NSPanel, NSWindowDelegate {
    private static var current: NetworkHistoryWindow?

    static func present(service: EnvironmentGuardService, language: AppLanguage) {
        let window = current ?? NetworkHistoryWindow(service: service, language: language)
        current = window
        window.title = language.text("出口与风险历史", "Exit and risk history")
        window.contentViewController = NSHostingController(rootView: NetworkHistoryView(service: service, language: language))
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(service: EnvironmentGuardService, language: AppLanguage) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        minSize = NSSize(width: 560, height: 380)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        delegate = self
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func windowWillClose(_ notification: Notification) { if Self.current === self { Self.current = nil } }
}
