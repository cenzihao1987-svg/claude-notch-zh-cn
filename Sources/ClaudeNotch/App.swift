import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let monitor = AppMonitor()
    private var windows: [CGDirectDisplayID: IslandWindow] = [:]
    private var desktopWidget: DesktopWidgetWindow?
    private var clickMonitor: Any?
    private var fullscreenTimer: Timer?
    private var hoverTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        desktopWidget = DesktopWidgetWindow(model: model)
        observeDesktopWidget()
        Updater.shared.start()                          // Sparkle auto-updates
        monitor.start(onChange: { [weak self] in self?.sync() },   // display / Claude changes
                      onFrontmostProvider: { [weak self] provider in
                          self?.model.selectProvider(provider, persist: false)
                      })
        sync()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.windows.values.forEach { $0.updateHoverExpansion() } }
        }
        hoverTimer?.tolerance = 0.01
        // Hide-in-fullscreen: Space changes are the primary trigger; the poll catches the
        // enter-fullscreen transition early (before the Space switch lands) and any missed
        // notification. Re-armed whenever the toggle changes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(fullscreenMaybeChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        observeHideInFullscreen()
        refreshFullscreenTimer()
    }

    @objc private func fullscreenMaybeChanged() { updateVisibility() }

    /// Pre-hide on app activation. Cmd+Tab / Dock clicks fire this *before* the Space switch
    /// starts; the pill rides onto every Space, so waiting for the switch to land means it shows
    /// up over the fullscreen app and then has to disappear — a visible blink. When every window
    /// of the activated app lives on a fullscreen Space, landing there is inevitable: tuck the
    /// pill away now and it never appears over the fullscreen app at all. Mixed apps (fullscreen
    /// window plus desktop windows) are left alone, since activation might land on a desktop
    /// window; the settled-state machinery covers them after the switch.
    @objc private func appActivated(_ note: Notification) {
        guard model.hideInFullscreen,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        for window in windows.values where !window.isRetracted
            && SpaceInfo.appLivesOnlyOnFullscreenSpaces(
                pid: app.processIdentifier, on: window.screen
            ) {
            window.hide()
        }
        updateAggregatedExpansion()
    }

    /// The island should hide only when the user opted in *and* a fullscreen app owns the island's
    /// screen. Acts only on a change, so it's cheap to call often.
    private func updateVisibility() {
        for window in windows.values {
            let hide = model.hideInFullscreen && Self.fullscreenPresent(on: window.screen)
            if hide, !window.isRetracted {
                window.hide()
            } else if !hide, window.isRetracted || !window.isVisible {
                window.show()
            }
        }
        updateAggregatedExpansion()
    }

    /// True when a fullscreen app owns the island's display.
    ///
    /// Asks the WindowServer whether the display's active Space is a fullscreen Space (via the
    /// private SkyLight API in `SpaceInfo`). That's a definitive signal, unlike sniffing window
    /// bounds, which can't tell native fullscreen from a maximized/zoomed window and breaks on
    /// notch geometry. Permission-free (no Accessibility or Screen Recording).
    ///
    /// The transition check is OR'd in as an early hint: it fires at the *start* of the
    /// enter-fullscreen zoom (before the Space switch lands), so the pill tucks away as the
    /// transition begins rather than after it settles. SpaceInfo remains the authority for the
    /// settled state and for showing the pill again.
    private static func fullscreenPresent(on screen: NSScreen) -> Bool {
        return SpaceInfo.fullscreenSpaceActive(on: screen)
            || fullscreenTransitionUnderway(on: screen)
    }

    /// Early hint: during the enter-fullscreen zoom the front app's window covers the ENTIRE
    /// display — including the notch / menu-bar strip. A maximized window never does that (it
    /// starts below the strip), so this can't fire on merely-zoomed windows. It only accelerates
    /// the hide; it's never needed for correctness.
    private static func fullscreenTransitionUnderway(on screen: NSScreen) -> Bool {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let front = NSWorkspace.shared.frontmostApplication
        else { return false }
        let bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))   // global, top-left origin
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let frontPID = Int(front.processIdentifier)
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,               // ordinary app window
                  (w[kCGWindowOwnerPID as String] as? Int) == frontPID,
                  let bd = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: bd as! CFDictionary)
            else { continue }
            if abs(r.width - bounds.width) < 4, abs(r.minX - bounds.minX) < 4,
               r.minY - bounds.minY < 4, r.height >= bounds.height - 4 {
                return true
            }
        }
        return false
    }

    /// Arm a brisk poll only while the option is on. The Space-change notification is the
    /// authoritative trigger; the poll exists to catch the enter-transition early (the hint above
    /// needs sub-transition sampling to be useful) and to cover any missed notification.
    private func refreshFullscreenTimer() {
        fullscreenTimer?.invalidate()
        fullscreenTimer = nil
        if model.hideInFullscreen {
            fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateVisibility() }
            }
            fullscreenTimer?.tolerance = 0.05
        }
        updateVisibility()
    }

    private func observeHideInFullscreen() {
        withObservationTracking { _ = model.hideInFullscreen } onChange: { [weak self] in
            Task { @MainActor in self?.refreshFullscreenTimer(); self?.observeHideInFullscreen() }
        }
    }

    private func observeDesktopWidget() {
        desktopWidget?.setShown(model.showDesktopWidget)
        withObservationTracking { _ = model.showDesktopWidget } onChange: { [weak self] in
            Task { @MainActor in self?.observeDesktopWidget() }
        }
    }

    /// Push current notch geometry into the model and reposition the island to the notched
    /// screen. Runs on launch and on every display-configuration change.
    private func sync() {
        model.claudeRunning = monitor.claudeRunning
        model.codexRunning = monitor.codexRunning
        model.workBuddyRunning = monitor.workBuddyRunning
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.displayID.map { ($0, screen) }
        })
        let removedIDs = windows.keys.filter { screens[$0] == nil }
        for id in removedIDs {
            windows.removeValue(forKey: id)?.close()
        }
        for (id, screen) in screens {
            if let window = windows[id] {
                window.relayout(on: screen)
            } else {
                let window = IslandWindow(model: model, screen: screen) { [weak self] in
                    self?.updateAggregatedExpansion()
                }
                windows[id] = window
                window.relayout(on: screen)
            }
        }
        desktopWidget?.ensureVisible()
        updateVisibility()
    }

    private func updateAggregatedExpansion() {
        model.isExpanded = windows.values.contains(where: \.isExpanded)
        updateClickMonitor()
    }

    /// While expanded, any click outside the island collapses it.
    private func updateClickMonitor() {
        if model.isExpanded, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    Task { @MainActor in
                        self?.windows.values.forEach { $0.collapse() }
                    }
                }
        } else if !model.isExpanded, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }
}
