import AppKit

/// The only process-mutating boundaries used by launch/restart, replaceable in tests.
@MainActor
struct GuardLaunchActions {
    var installedURL: (String?) -> URL? = { GuardLauncher.installedURL(preferredPath: $0) }
    var running: () -> [NSRunningApplication] = { GuardLauncher.runningApplications }
    var quit: () -> Bool = { GuardLauncher.runningApplications.map { $0.terminate() }.allSatisfy { $0 } }
    var open: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication = {
        try await NSWorkspace.shared.openApplication(at: $0, configuration: $1)
    }
}
