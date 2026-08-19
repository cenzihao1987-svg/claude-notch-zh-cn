import AppKit
import Foundation

/// This fork is distributed without a notarized Sparkle feed. The update action opens its
/// GitHub releases page, avoiding unverified background updates from the upstream project.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let releasesURL = URL(
        string: "https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases"
    )!

    func start() {}

    func checkForUpdates() { NSWorkspace.shared.open(Self.releasesURL) }
}
