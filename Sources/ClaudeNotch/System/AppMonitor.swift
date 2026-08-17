import AppKit

extension NSScreen {
    /// The screen the island should live on: a notched one if present, else the main screen.
    static var island: NSScreen? {
        screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? main ?? screens.first
    }
}

@MainActor @Observable
final class AppMonitor {
    var claudeRunning = false
    /// Notch metrics for the main screen. width==0 => no notch (use pill fallback).
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 0

    private let claudeBundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    /// ChatGPT.app 的真实 bundle id，实测确认——按常识猜 com.openai.chat 会猜错。
    private let codexBundleIDs = ["com.openai.codex"]
    private var onChange: (() -> Void)?
    private var onFrontmostProvider: ((UsageProviderID) -> Void)?

    func start(onChange: @escaping () -> Void,
               onFrontmostProvider: @escaping (UsageProviderID) -> Void = { _ in }) {
        self.onChange = onChange
        self.onFrontmostProvider = onFrontmostProvider
        updateNotch()
        updateClaude()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateClaude() }
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
                Task { @MainActor in self?.updateNotch(); self?.onChange?() }
        }
    }

    /// 前台切到 Claude 或 ChatGPT 时报告对应 provider；切到别的应用不报告，保持当前不变。
    /// 与 updateClaude 同样只做精确匹配，不用 contains 那种模糊判断。
    private func reportFrontmost(_ bundleID: String?) {
        guard let bundleID else { return }
        if claudeBundleIDs.contains(bundleID) {
            onFrontmostProvider?(.claude)
        } else if codexBundleIDs.contains(bundleID) {
            onFrontmostProvider?(.codex)
        }
    }

    private func updateClaude() {
        // Exact bundle-id match only — a loose contains("claude") would
        // false-positive on other apps (e.g. third-party usage trackers).
        let running = NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier else { return false }
            return claudeBundleIDs.contains(id)
        }
        if running != claudeRunning { claudeRunning = running; onChange?() }
    }

    private func updateNotch() {
        guard let screen = NSScreen.island else { return }
        notchHeight = screen.safeAreaInsets.top
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        } else {
            notchWidth = 0
        }
    }
}
