import Foundation
import SQLite3

func openWorkBuddyDatabaseReadOnly(at url: URL) -> OpaquePointer? {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    if sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
       sqlite3_exec(database, "PRAGMA schema_version", nil, nil, nil) == SQLITE_OK {
        return database
    }
    if let database { sqlite3_close(database) }
    database = nil
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    if let size = try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       size > 0 {
        return nil
    }
    let immutableURI = url.absoluteString + "?mode=ro&immutable=1"
    let fallbackFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(immutableURI, &database, fallbackFlags, nil) == SQLITE_OK else {
        if let database { sqlite3_close(database) }
        return nil
    }
    return database
}

struct WorkBuddyLocalUsageRead: Equatable, Sendable {
    let dailyUsage: [WorkBuddyDailyUsage]
    let matchedRequests: Int
    let totalRequests: Int
}

/// Reconstructs recent WorkBuddy credit consumption from its read-only local task records.
/// Transcript content is never retained or logged; only request IDs and timestamps are inspected.
actor WorkBuddyLocalUsageReader {
    private let databaseURL: URL
    private let projectsURL: URL
    private var cached: (value: WorkBuddyLocalUsageRead, at: Date)?
    private let cacheTTL: TimeInterval = 60

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db"),
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects", isDirectory: true)
    ) {
        self.databaseURL = databaseURL
        self.projectsURL = projectsURL
    }

    func read(
        force: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Result<WorkBuddyLocalUsageRead, WorkBuddyUsageError> {
        if !force, let cached, now.timeIntervalSince(cached.at) < cacheTTL {
            return .success(cached.value)
        }
        do {
            let value = try Self.read(
                databaseURL: databaseURL,
                projectsURL: projectsURL,
                now: now,
                calendar: calendar
            )
            cached = (value, now)
            return .success(value)
        } catch {
            return .failure(.localUsageUnavailable)
        }
    }

    private static func read(
        databaseURL: URL,
        projectsURL: URL,
        now: Date,
        calendar: Calendar
    ) throws -> WorkBuddyLocalUsageRead {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let bySession = try creditsBySession(from: databaseURL, updatedSince: start)
        let allCredits = bySession.values.reduce(into: [String: Double]()) { result, credits in
            for (requestID, value) in credits where result[requestID] == nil {
                result[requestID] = value
            }
        }

        var timestamps: [String: Date] = [:]
        if !allCredits.isEmpty {
            guard FileManager.default.fileExists(atPath: projectsURL.path) else {
                throw WorkBuddyUsageError.localUsageUnavailable
            }
            var pending = Set(allCredits.keys)
            for transcript in transcriptURLs(in: projectsURL, sessionIDs: Set(bySession.keys)) {
                try collectTimestamps(from: transcript, pending: &pending, timestamps: &timestamps)
                if pending.isEmpty { break }
            }
        }

        var dailyTotals: [Date: Double] = [:]
        for (requestID, timestamp) in timestamps {
            guard timestamp >= start, timestamp < end, let credits = allCredits[requestID] else { continue }
            dailyTotals[calendar.startOfDay(for: timestamp), default: 0] += credits
        }
        let dailyUsage = (0...6).compactMap { offset -> WorkBuddyDailyUsage? in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            return .init(date: date, credits: dailyTotals[date] ?? 0)
        }
        return .init(
            dailyUsage: dailyUsage,
            matchedRequests: timestamps.count,
            totalRequests: allCredits.count
        )
    }

    private static func creditsBySession(
        from databaseURL: URL,
        updatedSince start: Date
    ) throws -> [String: [String: Double]] {
        guard let database = openWorkBuddyDatabaseReadOnly(at: databaseURL) else {
            throw WorkBuddyUsageError.localUsageUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let sql = """
        SELECT s.id, su.credit_json
        FROM sessions s
        JOIN session_usage su ON su.session_id = s.id
        WHERE s.updated_at >= ? AND su.credit_json IS NOT NULL AND su.credit_json != ''
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw WorkBuddyUsageError.localUsageUnavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970 * 1_000))

        var result: [String: [String: Double]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idValue = sqlite3_column_text(statement, 0),
                  let jsonValue = sqlite3_column_text(statement, 1) else { continue }
            let sessionID = String(cString: idValue)
            let data = Data(String(cString: jsonValue).utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var credits: [String: Double] = [:]
            for (requestID, rawValue) in object {
                if let value = rawValue as? NSNumber {
                    credits[requestID] = value.doubleValue
                } else if let value = rawValue as? String, let number = Double(value) {
                    credits[requestID] = number
                }
            }
            if !credits.isEmpty { result[sessionID] = credits }
        }
        return result
    }

    private static func transcriptURLs(in projectsURL: URL, sessionIDs: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var primary: [URL] = []
        var subagents: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            if sessionIDs.contains(stem) {
                primary.append(url)
            } else if url.pathComponents.contains(where: sessionIDs.contains) {
                subagents.append(url)
            }
        }
        return primary.sorted { $0.path < $1.path } + subagents.sorted { $0.path < $1.path }
    }

    private static func collectTimestamps(
        from transcriptURL: URL,
        pending: inout Set<String>,
        timestamps: inout [String: Date]
    ) throws {
        let handle = try FileHandle(forReadingFrom: transcriptURL)
        defer { try? handle.close() }
        var buffer = Data()
        while !pending.isEmpty, let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                inspect(line: line, pending: &pending, timestamps: &timestamps)
                if pending.isEmpty { return }
            }
        }
        if !buffer.isEmpty {
            inspect(line: buffer, pending: &pending, timestamps: &timestamps)
        }
    }

    private static func inspect(
        line: Data,
        pending: inout Set<String>,
        timestamps: inout [String: Date]
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let providerData = object["providerData"] as? [String: Any],
              let requestID = providerData["conversationRequestId"] as? String,
              pending.contains(requestID),
              let timestamp = object["timestamp"] as? NSNumber else { return }
        timestamps[requestID] = Date(timeIntervalSince1970: timestamp.doubleValue / 1_000)
        pending.remove(requestID)
    }
}
