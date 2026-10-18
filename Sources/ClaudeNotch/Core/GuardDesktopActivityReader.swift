import AppKit
import Foundation

enum GuardDesktopActivity: String, Codable, Sendable { case active, inactive, unknown }

/// Process presence is an exposure proxy, not a claim that particular account traffic was sent.
@MainActor
enum GuardDesktopActivityReader {
    static func current() -> GuardDesktopActivity {
        if !GuardLauncher.runningApplications.isEmpty { return .active }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appPaths = ["/Applications/Claude.app/", home.appendingPathComponent("Applications/Claude.app").path + "/"]
            + [GuardLauncher.installedURL()?.path].compactMap { $0.map { $0 + "/" } }
        return classify(desktopRunning: false, processes: GuardExecutionInspector.checkedProcesses(),
            appPaths: appPaths, home: home)
    }

    static func sample(start: GuardDesktopActivity, end: GuardDesktopActivity, lifecycleChanged: Bool) -> GuardDesktopActivity {
        !lifecycleChanged && start == end ? start : .unknown
    }

    static func classify(desktopRunning: Bool, processes: [GuardRuntimeProcess]?, appPaths: [String], home: URL) -> GuardDesktopActivity {
        if desktopRunning { return .active }
        guard let processes else { return .unknown }
        let runtime = home.appendingPathComponent("Library/Application Support/Claude").path + "/"
        let cli = home.appendingPathComponent(".local/share/claude/versions").path + "/"
        var residual = false
        for process in processes {
            if process.path.hasPrefix(cli) { return .active }
            guard appPaths.contains(where: { process.path.hasPrefix($0) }) || process.path.hasPrefix(runtime) else { continue }
            let name = URL(fileURLWithPath: process.path).lastPathComponent.lowercased()
            if ["claude", "claude-code", "cowork", "vm", "vmm"].contains(name)
                || name.contains("virtualmachine") || process.path.contains("/claude-code-vm/") || process.path.contains("/vm_bundles/") { return .active }
            residual = true
        }
        return residual ? .unknown : .inactive
    }
}
