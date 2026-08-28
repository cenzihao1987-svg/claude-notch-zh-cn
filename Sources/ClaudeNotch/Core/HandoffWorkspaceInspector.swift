import Foundation

enum HandoffWorkspaceInspector {
    static func inspect(cwd: String) -> HandoffWorkspaceState {
        guard !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd),
              let status = runGit(["-C", cwd, "status", "--porcelain=v1", "-z",
                                   "--untracked-files=all"]) else {
            return HandoffWorkspaceState()
        }

        let branch = runGit(["-C", cwd, "branch", "--show-current"])
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var changed: [String] = []
        var untracked: [String] = []
        var skipRenameSource = false

        for record in status.split(separator: 0) {
            guard !skipRenameSource else {
                skipRenameSource = false
                continue
            }
            let bytes = Array(record)
            guard bytes.count >= 4,
                  let state = String(bytes: bytes.prefix(2), encoding: .utf8),
                  let path = String(bytes: bytes.dropFirst(3), encoding: .utf8),
                  !path.isEmpty, !HandoffRedactor.isSensitivePath(path) else { continue }
            if state == "??" { untracked.append(path) }
            else { changed.append(path) }
            if state.contains("R") || state.contains("C") { skipRenameSource = true }
        }

        return HandoffWorkspaceState(
            gitBranch: branch,
            changedFiles: Array(Set(changed)).sorted(),
            untrackedFiles: Array(Set(untracked)).sorted()
        )
    }

    private static func runGit(_ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
