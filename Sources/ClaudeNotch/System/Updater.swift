import AppKit
import Foundation

/// This fork is distributed without a notarized Sparkle feed. The update action opens its
/// GitHub releases page, avoiding unverified background updates from the upstream project.
@MainActor
final class Updater {
    static let shared = Updater()

    /// This fork's repository, rather than the upstream tracker, is the update destination.
    static let repositoryURL = URL(string: "https://github.com/cenzihao1987-svg/claude-notch-zh-cn")!
    private static let releasesURL = repositoryURL.appendingPathComponent("releases/latest")

    func start() {}

    func checkForUpdates() { NSWorkspace.shared.open(Self.releasesURL) }
}
