import Foundation

private enum CodexRequestID {
    static let firstThreadUsage = 100
}

actor CodexUsageProvider {
    private let transport = CodexAppServerTransport()
    /// The transport blocks on pipe reads behind NSCondition waits (worst case ~20s of timeouts),
    /// so it runs on its own utility queue. It must never run on the cooperative pool — actors
    /// execute there, and blocking a cooperative thread starves every other task in the app.
    private static let transportQueue = DispatchQueue(label: "codex-app-server", qos: .utility)

    func fetch(forecast: CodexResetForecast? = nil) async -> ProviderUsageSnapshot {
        let transport = transport
        return await withCheckedContinuation { continuation in
            Self.transportQueue.async {
                continuation.resume(returning: Self.snapshot(using: transport, forecast: forecast))
            }
        }
    }

    private static func snapshot(
        using transport: CodexAppServerTransport,
        forecast: CodexResetForecast?
    ) -> ProviderUsageSnapshot {
        do {
            let exchange = try transport.fetch()
            let account = exchange.decode(CodexAccountResponse.self, id: 2)
            let rateLimits = exchange.decode(CodexRateLimitsResponse.self, id: 3)
            let usage = exchange.decode(CodexAccountUsageResponse.self, id: 4)
            let threads = exchange.decode(CodexThreadListResponse.self, id: 5)
            let threadTokens = Dictionary(uniqueKeysWithValues:
                (threads?.data.prefix(3).enumerated().compactMap { index, thread in
                    let response = exchange.decode(
                        CodexThreadUsageResponse.self,
                        id: CodexRequestID.firstThreadUsage + index
                    )
                    let total = response?.threadUsage?.totalTokens
                        ?? CodexThreadTokenReader.totalTokens(at: thread.path)
                    return total.map { (thread.id, $0) }
                } ?? [])
            )
            // A result that arrived but no longer decodes means the app-server's schema moved.
            // Surface that instead of silently dropping tiles, so a future Codex update shows a
            // status line rather than a mysteriously empty island.
            var errors = exchange.errors
            let decodes: [(Int, Any?, String)] = [
                (2, account, "account"), (3, rateLimits, "rate limits"),
                (4, usage, "usage"), (5, threads, "tasks"),
            ]
            for (id, decoded, name) in decodes where exchange.hasResult(id) && decoded == nil {
                errors[id] = "Codex \(name) response not recognized"
            }
            return CodexSnapshotMapper.make(
                account: account,
                rateLimits: rateLimits,
                usage: usage,
                threads: threads,
                threadTokens: threadTokens,
                errors: errors,
                forecast: forecast,
                now: Date()
            )
        } catch {
            return .unavailable(.codex, message: error.localizedDescription)
        }
    }
}

struct CodexAccountResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let type: String
        let planType: String?
    }

    let account: Account?
    let requiresOpenaiAuth: Bool
}

struct CodexRateLimitsResponse: Decodable, Sendable {
    struct Credits: Decodable, Sendable {
        let balance: String?
        let hasCredits: Bool
        let unlimited: Bool
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct Snapshot: Decodable, Sendable {
        let credits: Credits?
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let spendControlReached: Bool?
    }

    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
}

struct CodexAccountUsageResponse: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        let lifetimeTokens: Int?
        let peakDailyTokens: Int?
        let longestRunningTurnSec: Int?
        let currentStreakDays: Int?
        let longestStreakDays: Int?
    }

    struct DailyBucket: Decodable, Sendable {
        let startDate: String
        let tokens: Int
    }

    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?
}

struct CodexThreadListResponse: Decodable, Sendable {
    struct Thread: Decodable, Sendable {
        let id: String
        let cwd: String
        let name: String?
        let path: String?
        let updatedAt: Int
    }

    let data: [Thread]
}

struct CodexThreadUsageResponse: Decodable, Sendable {
    struct ThreadUsage: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            let totalTokens: Int?
        }

        let threadId: String
        let groups: [Group]

        var totalTokens: Int? {
            let totals = groups.compactMap(\.totalTokens)
            return totals.isEmpty ? nil : totals.reduce(0, +)
        }
    }

    let threadUsage: ThreadUsage?
}

enum CodexThreadTokenReader {
    private static let maximumTailBytes: UInt64 = 2 * 1_024 * 1_024

    static func totalTokens(at path: String?) -> Int? {
        guard let path, path.hasSuffix(".jsonl"), isInsideCodexDataDirectory(path),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > maximumTailBytes ? size - maximumTailBytes : 0)
            return totalTokens(in: try handle.readToEnd() ?? Data())
        } catch {
            return nil
        }
    }

    static func totalTokens(in data: Data) -> Int? {
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tokens = (usage["total_tokens"] as? NSNumber)?.intValue else { continue }
            return tokens
        }
        return nil
    }

    private static func isInsideCodexDataDirectory(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        return resolved.hasPrefix(home + "/.codex/sessions/")
            || resolved.hasPrefix(home + "/.codex/archived_sessions/")
    }
}

enum CodexSnapshotMapper {
    static func make(
        account: CodexAccountResponse?,
        rateLimits: CodexRateLimitsResponse?,
        usage: CodexAccountUsageResponse?,
        threads: CodexThreadListResponse?,
        threadTokens: [String: Int] = [:],
        errors: [Int: String] = [:],
        forecast: CodexResetForecast? = nil,
        now: Date
    ) -> ProviderUsageSnapshot {
        let limits = rateLimits.map(makeLimits) ?? []
        let series = weekSeries(usage, now: now)
        let todayTokens = usage.flatMap { usage in
            usage.dailyUsageBuckets?.first(where: { $0.startDate == dayString(now) })?.tokens
        }
        let lifetimeTokens = usage?.summary.lifetimeTokens
        let accountPlan = account?.account?.planType
        let ratePlan = rateLimits?.rateLimits.planType
        let planName = (accountPlan ?? ratePlan).map(planLabel)
        let credits = rateLimits.flatMap(creditsLabel)

        // Order = display priority. The chart layout shows only the first slot or two next to the
        // limit windows, so live numbers lead (today, credits, yesterday); the page-2 tiles pull
        // all-time and peak by id, and the remainder only ever fills the no-feed fallback grid.
        var stats: [UsageStatMetric] = []
        if let todayTokens {
            stats.append(.init(id: "tokens-today", label: "tokens today · account",
                               value: Fmt.tokens(todayTokens), subtitle: nil))
        }
        if let credits {
            stats.append(.init(id: "credits", label: "credits", value: credits, subtitle: nil))
        }
        // The account feed often posts today's bucket late; keep yesterday even when it is zero,
        // otherwise the fixed summary grid leaves a conspicuous empty card slot.
        if series.count == 7, let yesterday = series.dropLast().last {
            stats.append(.init(id: "tokens-yesterday", label: "yesterday · account",
                               value: Fmt.tokens(yesterday.tokens), subtitle: nil))
        }
        // 「套餐」是一次性信息（看一眼就知道自己是 Plus），这个位置换成会变的重置提醒。
        // 永远 append，没有数据时是「重置 / —」，六宫格不会因为断网塌成五格。
        stats.append(CodexResetTile.make(limits: limits, forecast: forecast, now: now))
        if let lifetimeTokens {
            stats.append(.init(id: "tokens-lifetime", label: "tokens · all-time",
                               value: Fmt.tokens(lifetimeTokens), subtitle: nil))
        }
        if let peak = usage?.summary.peakDailyTokens, peak > 0 {
            stats.append(.init(id: "peak-day", label: "peak day",
                               value: Fmt.tokens(peak), subtitle: nil))
        }
        if let turn = usage?.summary.longestRunningTurnSec, turn > 0 {
            stats.append(.init(id: "longest-task", label: "longest task",
                               value: turnLabel(turn), subtitle: nil))
        }

        let sessions: [UsageSessionMetric] = threads?.data.prefix(3).map { thread in
            let title = threadName(thread)
            return UsageSessionMetric(
                id: thread.id,
                name: title,
                cost: nil,
                tokens: threadTokens[thread.id],
                last: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
                taskReference: AgentTaskReference(
                    provider: .codex,
                    sessionID: thread.id,
                    title: title,
                    cwd: thread.cwd,
                    workspaceRoots: [thread.cwd],
                    transcriptPath: thread.path
                )
            )
        } ?? []

        var message: String?
        if spendControlReached(rateLimits) {
            message = "Spend limit reached"
        } else if account?.account?.type == "apiKey", usage == nil {
            message = "Account usage requires ChatGPT sign-in"
        } else if !errors.isEmpty, limits.isEmpty || usage == nil {
            // Surface the first problem whenever a whole section is missing — including partial
            // failures, where limits render but usage silently didn't (or vice versa).
            message = errors.sorted { $0.key < $1.key }.first?.value
        }

        return ProviderUsageSnapshot(
            provider: .codex,
            limits: limits,
            stats: stats,
            todayTokens: todayTokens,
            lifetimeTokens: lifetimeTokens,
            dailySeries: series,
            chartTitle: "last 7 days · account",
            sessionsTitle: "recent tasks",
            sessions: sessions,
            planName: planName,
            source: "Codex app-server",
            fetchedAt: now,
            statusMessage: message
        )
    }

    private static func makeLimits(_ response: CodexRateLimitsResponse) -> [UsageLimitMetric] {
        // Mirrors official Codex snapshot handling (tui/src/app_server_session.rs): the top-level
        // snapshot always comes first, and by-id entries are appended only when they don't
        // duplicate it (matched by map key or the snapshot's own limitId). The previous behavior
        // dropped the top-level snapshot whenever the map existed, which would lose windows the
        // map doesn't repeat.
        let primary = response.rateLimits
        let primaryID = primary.limitId
        var buckets: [(String, CodexRateLimitsResponse.Snapshot)] = [(primaryID ?? "codex", primary)]
        for (key, snapshot) in (response.rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) {
            let duplicatesPrimary = primaryID.map { $0 == key || $0 == snapshot.limitId } ?? false
            if !duplicatesPrimary { buckets.append((key, snapshot)) }
        }

        let usesBucketPrefix = buckets.count > 1
        return buckets.flatMap { key, snapshot in
            let bucketName = snapshot.limitName ?? snapshot.limitId ?? key
            return makeLimits(
                prefix: key,
                snapshot: snapshot,
                bucketName: bucketName,
                usesBucketPrefix: usesBucketPrefix
            )
        }
    }

    private static func makeLimits(
        prefix: String,
        snapshot: CodexRateLimitsResponse.Snapshot,
        bucketName: String,
        usesBucketPrefix: Bool
    ) -> [UsageLimitMetric] {
        let raw = [
            (sourceOrder: 0, metric: makeLimit(prefix: prefix, kind: "primary",
                                               window: snapshot.primary,
                                               bucketName: bucketName,
                                               usesBucketPrefix: usesBucketPrefix)),
            (sourceOrder: 1, metric: makeLimit(prefix: prefix, kind: "secondary",
                                               window: snapshot.secondary,
                                               bucketName: bucketName,
                                               usesBucketPrefix: usesBucketPrefix)),
        ].compactMap { entry in
            entry.metric.map { (sourceOrder: entry.sourceOrder, metric: $0) }
        }

        return raw.sorted { lhs, rhs in
            let lhsOrder = durationOrder(lhs.metric.label)
            let rhsOrder = durationOrder(rhs.metric.label)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.sourceOrder < rhs.sourceOrder
        }.map(\.metric)
    }

    private static func makeLimit(
        prefix: String,
        kind: String,
        window: CodexRateLimitsResponse.Window?,
        bucketName: String,
        usesBucketPrefix: Bool
    ) -> UsageLimitMetric? {
        guard let window else { return nil }
        let duration = durationLabel(window.windowDurationMins)
        let label = usesBucketPrefix ? "\(bucketName) · \(duration)" : duration
        return UsageLimitMetric(
            id: "\(prefix)-\(kind)",
            label: label,
            usedFraction: Double(window.usedPercent) / 100,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func durationOrder(_ label: String) -> Int {
        let duration = label.split(separator: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
        switch duration {
        case "5-Hour": return 0
        case "Daily": return 1
        case "7-Day": return 2
        case "Monthly": return 3
        case "Annual": return 4
        default: return 5
        }
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Limit" }
        // Official Codex matches window durations within ±5% of the canonical windows
        // (tui/src/chatwidget/rate_limits.rs, is_approximate_window), so a 299-minute window
        // still reads as the 5-hour limit instead of "299-Min".
        func approximately(_ expected: Int) -> Bool {
            let m = Double(minutes), e = Double(expected)
            return m >= e * 0.95 && m <= e * 1.05
        }
        if approximately(300) { return "5-Hour" }
        if approximately(1_440) { return "Daily" }
        if approximately(10_080) { return "7-Day" }
        if approximately(43_200) { return "Monthly" }
        if approximately(525_600) { return "Annual" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-Day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-Hour" }
        return "\(minutes)-Min"
    }

    /// "15h 15m" / "42m" for the longest-running task turn.
    private static func turnLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func spendControlReached(_ response: CodexRateLimitsResponse?) -> Bool {
        guard let response else { return false }
        let snapshots = [response.rateLimits] + (response.rateLimitsByLimitId?.values.map { $0 } ?? [])
        return snapshots.contains { $0.spendControlReached == true }
    }

    /// nil (no tile at all) unless there is actually something to say — a "credits: 0" tile is
    /// dead weight on a page this small.
    private static func creditsLabel(_ response: CodexRateLimitsResponse) -> String? {
        let snapshots = [response.rateLimits] + (response.rateLimitsByLimitId?.values.map { $0 } ?? [])
        guard let credits = snapshots.compactMap(\.credits).first else { return nil }
        if credits.unlimited { return "unlimited" }
        if let balance = credits.balance, !balance.isEmpty,
           Double(balance).map({ $0 > 0 }) ?? true {   // non-numeric strings pass through as-is
            return balance
        }
        return credits.hasCredits ? "available" : nil
    }

    private static func planLabel(_ raw: String) -> String {
        "Codex " + raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The last seven calendar days (oldest first, ending today), zero-filled from the account's
    /// daily buckets. Empty when the account provides no daily feed at all (e.g. API-key auth),
    /// which tells the UI to fall back to the plain tile grid.
    private static func weekSeries(_ usage: CodexAccountUsageResponse?, now: Date) -> [DailyUsagePoint] {
        guard let buckets = usage?.dailyUsageBuckets, !buckets.isEmpty else { return [] }
        let byDay = Dictionary(buckets.map { ($0.startDate, $0.tokens) }, uniquingKeysWith: +)
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { back in
            // startOfDay so a bar's identity is stable across refreshes (SwiftUI diffs by date).
            guard let raw = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let day = calendar.startOfDay(for: raw)
            return DailyUsagePoint(date: day, tokens: byDay[dayString(day)] ?? 0)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func threadName(_ thread: CodexThreadListResponse.Thread) -> String {
        if let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let folder = (thread.cwd as NSString).lastPathComponent
        return folder.isEmpty ? "Codex task" : folder
    }
}

private struct CodexRPCExchange: Sendable {
    let results: [Int: Data]
    let errors: [Int: String]

    func decode<T: Decodable>(_ type: T.Type, id: Int) -> T? {
        guard let data = results[id] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func hasResult(_ id: Int) -> Bool { results[id] != nil }
}

private struct CodexAppServerTransport: Sendable {
    func fetch() throws -> CodexRPCExchange {
        let executable = try findExecutable()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = CodexRPCCollector()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { _ in collector.markProcessExited() }

        do {
            try process.run()
            try send([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "notch-usage-tracker",
                        "title": "Notch Usage Tracker",
                        "version": AppInfo.version,
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ], to: input.fileHandleForWriting)
            try collector.wait(for: [1], timeout: 8)

            try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]],
                     to: input.fileHandleForWriting)
            try sendRequest(id: 2, method: "account/read", params: ["refreshToken": false],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 3, method: "account/rateLimits/read", params: [:],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 4, method: "account/usage/read", params: [:],
                            to: input.fileHandleForWriting)
            try sendRequest(id: 5, method: "thread/list", params: [
                "limit": 10,
                "sortKey": "updated_at",
                "sortDirection": "desc",
            ], to: input.fileHandleForWriting)
            try collector.wait(for: [2, 3, 4, 5], timeout: 12)

            let threads = collector.exchange.decode(CodexThreadListResponse.self, id: 5)
            let recentThreads = threads.map { Array($0.data.prefix(3)) } ?? []
            let requests = recentThreads.enumerated().map {
                index, thread in
                (id: CodexRequestID.firstThreadUsage + index, threadID: thread.id)
            }
            for request in requests {
                try sendRequest(
                    id: request.id,
                    method: "account/usage/read",
                    params: ["threadId": request.threadID],
                    to: input.fileHandleForWriting
                )
            }
            if !requests.isEmpty {
                // Per-task usage is optional. Older app-server builds may not expose it, and a
                // slow response must not hide the account limits that already arrived.
                try? collector.wait(for: Set(requests.map(\.id)), timeout: 5)
            }
        } catch {
            cleanup(process: process, input: input, output: output)
            if let providerError = error as? CodexProviderError { throw providerError }
            throw CodexProviderError.transport
        }

        cleanup(process: process, input: input, output: output)
        return collector.exchange
    }

    private func sendRequest(id: Int, method: String, params: [String: Any],
                             to handle: FileHandle) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: handle)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func cleanup(process: Process, input: Pipe, output: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        // Runs on the provider's dedicated queue, so a short bounded wait is fine: give SIGTERM
        // up to ~1.5s to land, then SIGKILL. A wedged app-server must never accumulate — this is
        // respawned on every poll.
        for _ in 0..<15 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func findExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["CODEX_NOTCH_BINARY"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexProviderError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

private final class CodexRPCCollector: @unchecked Sendable {
    private static let maximumBufferedBytes = 8 * 1_024 * 1_024
    private let condition = NSCondition()
    private var buffer = Data()
    private var results: [Int: Data] = [:]
    private var errors: [Int: String] = [:]
    private var completedIDs = Set<Int>()
    private var processExited = false
    private var streamError: CodexProviderError?
    private var receivedBytes = 0

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            processExited = true
            condition.broadcast()
            return
        }
        guard data.count <= Self.maximumBufferedBytes - receivedBytes else {
            streamError = .responseTooLarge
            buffer.removeAll(keepingCapacity: false)
            condition.broadcast()
            return
        }
        receivedBytes += data.count
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    func markProcessExited() {
        condition.lock()
        processExited = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for ids: Set<Int>, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !ids.isSubset(of: completedIDs), !processExited, streamError == nil {
            if !condition.wait(until: deadline) { break }
        }
        if let streamError { throw streamError }
        guard ids.isSubset(of: completedIDs) else {
            if processExited {
                throw CodexProviderError.transport
            }
            throw CodexProviderError.timeout
        }
    }

    var exchange: CodexRPCExchange {
        condition.lock()
        defer { condition.unlock() }
        return CodexRPCExchange(results: results, errors: errors)
    }

    private func consume(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              // Only RESPONSES complete our ids. Server-initiated requests carry both "id" and
              // "method" in their own id-space — one colliding with ours would otherwise record
              // an empty completion and silently blank that section.
              object["method"] == nil,
              let id = (object["id"] as? NSNumber)?.intValue else { return }
        if let result = object["result"], JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result) {
            results[id] = data
        }
        if object["error"] is [String: Any] {
            errors[id] = "Codex request failed"
        }
        completedIDs.insert(id)
        condition.broadcast()
    }
}

private enum CodexProviderError: LocalizedError {
    case executableNotFound
    case timeout
    case responseTooLarge
    case transport

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex executable not found"
        case .timeout:
            "Codex app-server timed out"
        case .responseTooLarge:
            "Codex app-server response was too large"
        case .transport:
            "Codex app-server request failed"
        }
    }
}
