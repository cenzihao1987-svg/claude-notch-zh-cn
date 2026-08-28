import AppKit
import CodexWidgetShared
import SwiftUI

@MainActor
final class DesktopWidgetWindow: NSPanel, NSWindowDelegate {
    private static let size = NSSize(width: 364, height: 170)
    private static let originXKey = "desktopWidgetOriginX"
    private static let originYKey = "desktopWidgetOriginY"
    private var restoringPosition = false

    init(model: AppModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        level = NSWindow.Level(rawValue: desktopIconLevel + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        delegate = self
        contentView = NSHostingView(rootView: DesktopCodexWidgetView(model: model))
        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShown(_ shown: Bool) {
        shown ? orderFrontRegardless() : orderOut(nil)
    }

    func ensureVisible() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        placeAtDefaultPosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard !restoringPosition else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: Self.originXKey)
        UserDefaults.standard.set(frame.origin.y, forKey: Self.originYKey)
    }

    private func restorePosition() {
        restoringPosition = true
        defer { restoringPosition = false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil,
           defaults.object(forKey: Self.originYKey) != nil {
            setFrameOrigin(NSPoint(
                x: defaults.double(forKey: Self.originXKey),
                y: defaults.double(forKey: Self.originYKey)
            ))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return }
        }
        placeAtDefaultPosition()
    }

    private func placeAtDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.maxX - Self.size.width - 24,
            y: visible.minY + 24
        ))
    }
}

private struct DesktopCodexWidgetView: View {
    let model: AppModel

    var body: some View {
        CodexQuotaCard(
            snapshot: model.codexWidgetSnapshot,
            language: model.language == .english ? .english : .chinese
        )
        .frame(width: 364, height: 170)
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
    }
}
