import CryptoKit
import Darwin
import Foundation

struct GuardWebModuleManifest: Codable, Sendable {
    let `protocol`: Int
    let appVersion: String
    let bridgeSHA256: String
}

enum GuardWebEnvironmentReader {
    static let sessionKey = "CLAUDE_NOTCH_WEB_GUARD_SESSION"
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeNotch/Guard", isDirectory: true)
    static let reportURL = directory.appendingPathComponent("web-environment.json")

    static func prepareDirectory() throws {
        let manager = FileManager.default
        for folder in [directory.deletingLastPathComponent(), directory] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try manager.attributesOfItem(atPath: folder.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileReadNoPermission) }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// Bounded, owner-only regular-file reads; never follows a supplied or on-disk symlink.
    static func privateData(at url: URL, maxBytes: Int, requirePrivateOwner: Bool = true) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (!requirePrivateOwner || info.st_uid == getuid() && info.st_mode & 0o077 == 0),
              info.st_size > 0, info.st_size <= maxBytes else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { bytes in Darwin.read(descriptor, bytes.baseAddress, bytes.count) }
        guard count == data.count else { return nil }
        return data
    }

    static func state(client: GuardClient?, receipt: LaunchReceipt?, enabled: Bool, now: Date = .now) -> GuardWebState {
        guard enabled else { return .unavailable(.disabled) }
        guard let client, client.pid != nil else { return .unavailable(.notRunning) }
        let resources = URL(fileURLWithPath: client.path).appendingPathComponent("Contents/Resources")
        let manifestURL = resources.appendingPathComponent("claude-notch-webguard.json")
        guard let data = privateData(at: manifestURL, maxBytes: 4096, requirePrivateOwner: false) else { return .unavailable(.missingModule) }
        guard let manifest = try? JSONDecoder().decode(GuardWebModuleManifest.self, from: data), manifest.protocol == 1,
              manifest.appVersion == client.version,
              let bridge = privateData(at: resources.appendingPathComponent("claude-notch-webguard.cjs"), maxBytes: 32768, requirePrivateOwner: false),
              SHA256.hash(data: bridge).map({ String(format: "%02x", $0) }).joined() == manifest.bridgeSHA256 else {
            return .unavailable(.outdatedModule)
        }
        guard let receipt, receipt.matches(client), let session = receipt.webSession, session.count == 32 else { return .unavailable(.needsRelaunch) }
        guard let raw = privateData(at: reportURL, maxBytes: 32768) else {
            return .unavailable(now.timeIntervalSince(receipt.launchedAt) < 35 ? .waitingForPage : .unreadable)
        }
        let result = decode(raw, client: client, receipt: receipt, now: now)
        if case .unavailable(.unreadable) = result, now.timeIntervalSince(receipt.launchedAt) < 35 {
            return .unavailable(.waitingForPage)
        }
        return result
    }

    static func decode(_ data: Data, client: GuardClient, receipt: LaunchReceipt, now: Date) -> GuardWebState {
        guard data.count <= 32768, let value = try? JSONDecoder().decode(GuardWebReport.self, from: data),
              value.protocol == 1, value.pid == client.pid, receipt.matches(client),
              let session = receipt.webSession, session.count == 32, value.session == session,
              value.candidateCount >= 0, value.candidateCount <= 128, value.failedCount >= 0,
              value.failedCount <= 128, value.frames.count <= 8,
              value.candidateCount >= value.frames.count,
              value.failedCount == value.candidateCount - value.frames.count || value.candidateCount == 0 && value.failedCount == 1,
              value.capturedAt.isFinite else { return .unavailable(.unreadable) }
        let captured = Date(timeIntervalSince1970: value.capturedAt / 1000)
        guard captured >= receipt.launchedAt.addingTimeInterval(-2), captured.timeIntervalSince(now) <= 2 else { return .unavailable(.unreadable) }
        guard now.timeIntervalSince(captured) < 90 else { return .unavailable(.stale) }
        func valid(_ string: String, max: Int) -> Bool {
            !string.isEmpty && string.utf8.count <= max && !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard value.frames.allSatisfy({ frame in
            ["claude.ai", "Claude Desktop"].contains(frame.context) && valid(frame.language, max: 64) && valid(frame.locale, max: 64)
                && valid(frame.timeZone, max: 128) && (1...16).contains(frame.languages.count)
                && frame.languages.allSatisfy { valid($0, max: 64) }
        }) else { return .unavailable(.unreadable) }
        if value.candidateCount == 0 { return .unavailable(value.failedCount == 0 ? .waitingForPage : .unreadable) }
        return .observed(value)
    }
}
