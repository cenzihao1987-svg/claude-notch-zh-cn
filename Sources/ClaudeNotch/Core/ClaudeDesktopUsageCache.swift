import Foundation

enum ClaudeSubscriptionTier: Equatable, Sendable {
    case pro
    case max
}

/// A usage snapshot Claude Desktop has already fetched from claude.ai and written to its
/// Chromium disk cache. Reading it is credential-free and makes no network request.
struct ClaudeDesktopCachedUsage: Equatable, Sendable {
    let sessionPct: Double?
    let sessionResetsAt: Date?
    let weeklyPct: Double?
    let weeklyResetsAt: Date?
    let fetchedAt: Date

    func isFresh(now: Date = Date(), after interval: TimeInterval) -> Bool {
        if let sessionResetsAt, sessionResetsAt <= now { return false }
        return now.timeIntervalSince(fetchedAt) <= interval
    }
}

/// Reads Claude Desktop's cached `/usage` response. The cache format is an implementation detail,
/// so every failure is soft: a future Desktop/Chromium change simply falls back to the existing
/// network provider instead of breaking the app.
actor ClaudeDesktopUsageCache {
    private static let maxEntryBytes = 1_048_576
    private static let entryPrefix = "1/0/https://claude.ai/api/organizations/"
    private static let entrySuffix = "/usage"
    private static let zstdMagic = Data([0x28, 0xB5, 0x2F, 0xFD])

    private let directory: URL
    private var entryURL: URL?
    private var entryMTime: Date?
    private var cachedUsage: ClaudeDesktopCachedUsage?
    private var subscriptionEntryURL: URL?
    private var subscriptionEntryMTime: Date?
    private var cachedSubscriptionTier: ClaudeSubscriptionTier?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent(
            "Library/Application Support/Claude/Cache/Cache_Data",
            isDirectory: true
        )
    }

    func latest() -> ClaudeDesktopCachedUsage? {
        guard let candidate = findEntry() else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let size = values?.fileSize, size > 24, size <= Self.maxEntryBytes,
              let modified = values?.contentModificationDate
        else { return nil }

        if candidate == entryURL, modified == entryMTime { return cachedUsage }
        guard let data = try? Data(contentsOf: candidate, options: .mappedIfSafe),
              let json = decodeEntry(data, accepting: Self.isUsageKey),
              let usage = Self.parseUsageJSON(json, fetchedAt: modified)
        else { return nil }

        entryURL = candidate
        entryMTime = modified
        cachedUsage = usage
        return usage
    }

    /// Claude Desktop already caches the official organization profile used to render account
    /// features. Reading its capability names tells Pro from Max without another network request.
    func subscriptionTier() -> ClaudeSubscriptionTier? {
        guard let candidate = findSubscriptionEntry() else { return cachedSubscriptionTier }
        let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let size = values?.fileSize, size > 24, size <= Self.maxEntryBytes,
              let modified = values?.contentModificationDate
        else { return cachedSubscriptionTier }

        if candidate == subscriptionEntryURL, modified == subscriptionEntryMTime {
            return cachedSubscriptionTier
        }
        guard let data = try? Data(contentsOf: candidate, options: .mappedIfSafe),
              let json = decodeEntry(data, accepting: Self.isOrganizationProfileKey)
        else { return cachedSubscriptionTier }

        subscriptionEntryURL = candidate
        subscriptionEntryMTime = modified
        cachedSubscriptionTier = Self.parseSubscriptionJSON(json)
        return cachedSubscriptionTier
    }

    /// Chromium Simple Cache stores the key length at byte 12, the key at byte 24, then stream 0.
    /// Claude's current response uses zstd; raw JSON is accepted for forward/backward compatibility.
    private func decodeEntry(_ data: Data, accepting keyMatches: (String) -> Bool) -> Data? {
        guard let keyLength = Self.uint32LE(data, at: 12), keyLength > 0, keyLength <= 4096 else {
            return nil
        }
        let bodyOffset = 24 + Int(keyLength)
        guard bodyOffset < data.count,
              let key = String(data: data[24..<bodyOffset], encoding: .utf8),
              keyMatches(key)
        else { return nil }

        let body = Data(data[bodyOffset...])
        if body.first == Character("{").asciiValue { return body }
        guard body.starts(with: Self.zstdMagic) else { return nil }
        return decodeZstd(body)
    }

    private func findEntry() -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return urls.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 24, size <= Self.maxEntryBytes,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.1 > $1.1 }
        .lazy
        .map(\.0)
        .first(where: Self.isUsageEntry)
    }

    private func findSubscriptionEntry() -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return urls.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 24, size <= Self.maxEntryBytes,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.1 > $1.1 }
        .lazy
        .map(\.0)
        .first { Self.isCacheEntry($0, accepting: Self.isOrganizationProfileKey) }
    }

    private static func isUsageEntry(_ url: URL) -> Bool {
        isCacheEntry(url, accepting: isUsageKey)
    }

    private static func isCacheEntry(_ url: URL, accepting keyMatches: (String) -> Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24,
              let keyLength = uint32LE(header, at: 12), keyLength > 0, keyLength <= 4096,
              (try? handle.seek(toOffset: 24)) != nil,
              let keyData = try? handle.read(upToCount: Int(keyLength)),
              let key = String(data: keyData, encoding: .utf8)
        else { return false }
        return keyMatches(key)
    }

    private static func isUsageKey(_ key: String) -> Bool {
        key.hasPrefix(entryPrefix) && key.hasSuffix(entrySuffix)
    }

    private static func isOrganizationProfileKey(_ key: String) -> Bool {
        let prefix = "1/0/https://claude.ai/api/organizations/"
        guard key.hasPrefix(prefix) else { return false }
        let identifier = key.dropFirst(prefix.count)
        return !identifier.isEmpty && !identifier.contains("/") && !identifier.contains("?")
    }

    /// Only fixed trusted Homebrew paths are accepted. No shell and no inherited PATH lookup.
    /// Chromium appends metadata after the zstd frame, so zstd may exit non-zero after producing
    /// the complete JSON. Successful JSON parsing, not the process exit code, is authoritative.
    private func decodeZstd(_ input: Data) -> Data? {
        let fm = FileManager.default
        guard let executable = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            .first(where: fm.isExecutableFile(atPath:))
        else { return nil }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-c", "--no-progress"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !output.isEmpty, output.count <= Self.maxEntryBytes else { return nil }
        return output
    }

    static func parseUsageJSON(_ data: Data, fetchedAt: Date) -> ClaudeDesktopCachedUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func node(_ key: String) -> (Double?, Date?) {
            guard let value = obj[key] as? [String: Any] else { return (nil, nil) }
            let rawPct: Double? = (value["utilization"] as? NSNumber)?.doubleValue
            let pct = rawPct.map { min(1, max(0, $0 / 100)) }
            let reset = (value["resets_at"] as? String).flatMap(parseDate)
            return (pct, reset)
        }

        let (session, sessionReset) = node("five_hour")
        var (weekly, weeklyReset) = node("seven_day")
        if weekly == nil {
            let (opus, opusReset) = node("seven_day_opus")
            let (sonnet, sonnetReset) = node("seven_day_sonnet")
            weekly = [opus, sonnet].compactMap { $0 }.max()
            weeklyReset = opusReset ?? sonnetReset
        }
        guard session != nil || weekly != nil else { return nil }
        return ClaudeDesktopCachedUsage(
            sessionPct: session,
            sessionResetsAt: sessionReset,
            weeklyPct: weekly,
            weeklyResetsAt: weeklyReset,
            fetchedAt: fetchedAt
        )
    }

    static func parseSubscriptionJSON(_ data: Data) -> ClaudeSubscriptionTier? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = obj["capabilities"] as? [String]
        else { return nil }
        if capabilities.contains(where: { $0.hasPrefix("claude_max") }) { return .max }
        if capabilities.contains("claude_pro") { return .pro }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].enumerated().reduce(0) { value, element in
            value | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }
}
