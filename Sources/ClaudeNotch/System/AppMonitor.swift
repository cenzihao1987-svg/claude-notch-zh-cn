import AppKit

extension NSScreen {
    /// The screen the island should live on: a notched one if present, else the main screen.
    static var island: NSScreen? {
        screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? main ?? screens.first
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    var islandTopInset: CGFloat { safeAreaInsets.top > 0 ? safeAreaInsets.top : 32 }

    var islandNotchWidth: CGFloat {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return 190 }
        return frame.width - left.width - right.width
    }
}

@MainActor @Observable
final class AppMonitor {
    var claudeRunning = false
    var codexRunning = false
    var workBuddyRunning = false

    /// Use the same exact identities for activation events and running-app detection.
    nonisolated static func provider(forBundleID bundleID: String?) -> UsageProviderID? {
        switch bundleID {
        case "com.anthropic.claudefordesktop", "com.anthropic.claude": .claude
        case "com.openai.codex": .codex
        case "com.tencent.workbuddy.mac", "com.workbuddy.workbuddy": .workbuddy
        default: nil
        }
    }
    private var onChange: (() -> Void)?
    private var onFrontmostProvider: ((UsageProviderID) -> Void)?

    func start(onChange: @escaping () -> Void,
               onFrontmostProvider: @escaping (UsageProviderID) -> Void = { _ in }) {
        self.onChange = onChange
        self.onFrontmostProvider = onFrontmostProvider
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateRunningApps() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor in self?.reportFrontmost(id) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange?() }
        }
        updateRunningApps()
        reportFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Follow supported agent apps; unrelated apps leave the current provider unchanged.
    private func reportFrontmost(_ bundleID: String?) {
        guard let provider = Self.provider(forBundleID: bundleID) else { return }
        onFrontmostProvider?(provider)
    }

    private func updateRunningApps() {
        // Exact bundle-id match only — a loose contains("claude") would
        // false-positive on other apps (e.g. third-party usage trackers).
        let runningProviders = NSWorkspace.shared.runningApplications.compactMap { Self.provider(forBundleID: $0.bundleIdentifier) }
        let claude = runningProviders.contains(.claude)
        let codex = runningProviders.contains(.codex)
        let workBuddy = runningProviders.contains(.workbuddy)
        if claude != claudeRunning || codex != codexRunning || workBuddy != workBuddyRunning {
            claudeRunning = claude
            codexRunning = codex
            workBuddyRunning = workBuddy
            onChange?()
        }
    }
}
