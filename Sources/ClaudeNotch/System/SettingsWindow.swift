import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSWindow {
    private static var current: SettingsWindow?

    static func present(model: AppModel) {
        let window = current ?? SettingsWindow(model: model)
        if Self.current == nil {
            Self.current = window
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        // An .accessory app has no Dock icon, so ordering the window front doesn't bring the app
        // forward on its own — without this the settings window opens behind whatever was focused.
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model: AppModel

    private init(model: AppModel) {
        self.model = model
        super.init(contentRect: .zero,
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered,
                   defer: false)
        contentViewController = NSHostingController(rootView: SettingsView(model: model))
        isReleasedWhenClosed = false
        observeLanguage()
    }

    private func observeLanguage() {
        title = model.language.text("Claude Notch 设置", "Claude Notch Settings")
        withObservationTracking { _ = model.language } onChange: { [weak self] in
            Task { @MainActor in self?.observeLanguage() }
        }
    }
}
