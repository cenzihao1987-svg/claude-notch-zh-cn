import Foundation

enum WorkBuddyCredentialReader {
    /// Use the installed vendor runtime; no client patch, keychain access or saved plaintext.
    static func decrypt(_ envelope: String) throws -> String {
        let manager = FileManager.default
        let candidates = [URL(fileURLWithPath: "/Applications/WorkBuddy.app"),
                          manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WorkBuddy.app")]
        guard let app = candidates.first(where: {
            guard let id = Bundle(url: $0)?.bundleIdentifier else { return false }
            return ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"].contains(id)
        }), let executable = Bundle(url: app)?.executableURL,
              manager.isExecutableFile(atPath: executable.path),
              let script = scriptURL,
              let input = try? JSONSerialization.data(withJSONObject: ["$wbEncrypted": 1, "envelope": envelope]),
              input.count <= 32768 else { throw WorkBuddyUsageError.credentialsProtected }

        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        defer {
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
        }
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = [script.path]
        process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "TMPDIR"].contains($0.key) }
        process.environment?["ELECTRON_RUN_AS_NODE"] = "1"
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            try? stdout.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw WorkBuddyUsageError.credentialsProtected
        }
        guard exited.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { process.terminate() }
            try? stdout.fileHandleForReading.close()
            throw WorkBuddyUsageError.credentialsProtected
        }
        let data = stdout.fileHandleForReading.readData(ofLength: 65537)
        guard process.terminationStatus == 0, data.count <= 65536,
              let result = try? JSONDecoder().decode(TokenResult.self, from: data),
              !result.accessToken.isEmpty else { throw WorkBuddyUsageError.credentialsProtected }
        return result.accessToken
    }

    private struct TokenResult: Decodable { let accessToken: String }
    private static var scriptURL: URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")),
           let script = bundle.url(forResource: "read-current-token", withExtension: "cjs", subdirectory: "WorkBuddy") { return script }
        return Bundle.module.url(forResource: "read-current-token", withExtension: "cjs", subdirectory: "WorkBuddy")
    }
}
