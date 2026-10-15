import AppKit
import SwiftUI

@MainActor
final class EnvironmentGuardWindow: NSPanel, NSWindowDelegate {
    private static var current: EnvironmentGuardWindow?
    static var activePopupMenu: NSMenu?
    private let model: AppModel
    private var preferredHeight: CGFloat = GuardVisual.height
    private var maximumHeight: CGFloat = 1037
    private var availableFrame: NSRect?

    static func present(model: AppModel, on screen: NSScreen?) {
        let window = current ?? EnvironmentGuardWindow(model: model)
        current = window
        if let screen = screen ?? NSScreen.main {
            let area = screen.visibleFrame
            window.availableFrame = area
            window.maximumHeight = max(400, area.height - 48)
            window.resizeToContent(window.preferredHeight)
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                          y: area.midY - window.frame.height / 2))
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.environmentGuard.setWindowVisible(true)
    }

    private init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: GuardVisual.width, height: GuardVisual.height),
                   styleMask: [.borderless, .closable, .miniaturizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        contentViewController = NSHostingController(rootView: EnvironmentGuardView(
            model: model, onClose: { [weak self] in self?.close() },
            onMinimize: { [weak self] in self?.miniaturize(nil) },
            onZoom: { [weak self] in self?.toggleWindowHeight() },
            onPreferredHeight: { [weak self] height in self?.resizeToContent(height) }
        ))
        setContentSize(NSSize(width: GuardVisual.width, height: GuardVisual.height))
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        delegate = self
        observeLanguage()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if let menu = Self.activePopupMenu { menu.cancelTracking(); return }
        close()
    }

    private func resizeToContent(_ height: CGFloat) {
        preferredHeight = height
        let target = min(maximumHeight, max(400, height))
        guard abs(frame.height - target) > 0.5 else { return }
        var rect = frame
        let top = rect.maxY
        rect.size = NSSize(width: GuardVisual.width, height: target)
        rect.origin.y = top - target
        if let area = availableFrame {
            rect.origin.y = min(max(area.minY + 24, rect.origin.y), area.maxY - target - 24)
        }
        setFrame(rect, display: true)
    }

    private func toggleWindowHeight() {
        resizeToContent(abs(frame.height - min(maximumHeight, GuardVisual.height)) < 1 ? maximumHeight : GuardVisual.height)
    }

    func windowDidMiniaturize(_ notification: Notification) { model.environmentGuard.setWindowVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.environmentGuard.setWindowVisible(true) }

    func windowWillClose(_ notification: Notification) {
        model.environmentGuard.setWindowVisible(false)
        // Profiles live in the service; closed utility windows need not retain menu/view trees.
        if Self.current === self { Self.current = nil }
    }

    private func observeLanguage() {
        title = model.language.text("Claude 环境", "Claude Environment")
        withObservationTracking { _ = model.language } onChange: { [weak self] in
            Task { @MainActor in self?.observeLanguage() }
        }
    }
}
