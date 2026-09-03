import Foundation
import SQLite3

struct WorkBuddyCredentials: Equatable, Sendable {
    let accessToken: String
    let userID: String
    let enterpriseID: String?
    let domain: String?
    let expiresAt: Date?
}

struct WorkBuddyAccountUsage: Codable, Equatable, Sendable {
    let usageLeft: Double?
    let usageTotal: Double?
    let usageUsed: Double?
    let planName: String?
    let editionType: String?
    let refreshAt: Date?
    let expireAt: Date?
    let isUnlimited: Bool
}

struct WorkBuddyDailyUsage: Codable, Equatable, Sendable {
    let date: Date
    let credits: Double
}

struct WorkBuddyUsageCache: Codable, Equatable, Sendable {
    let usage: WorkBuddyAccountUsage?
    let fetchedAt: Date?
}

enum WorkBuddyUsageError: Error, Equatable, Sendable {
    case credentialsMissing
    case credentialsInvalid
    case credentialsExpired
    case unauthorized
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case networkUnavailable
    case databaseUnavailable
    case localUsageUnavailable

    var message: String {
        switch self {
        case .credentialsMissing: "未找到 WorkBuddy 登录信息"
        case .credentialsInvalid: "WorkBuddy 登录信息无效"
        case .credentialsExpired: "WorkBuddy 登录已过期，请打开 WorkBuddy"
        case .unauthorized: "WorkBuddy 登录已失效，请打开 WorkBuddy"
        case .rateLimited: "WorkBuddy 请求过于频繁"
        case .serviceUnavailable: "WorkBuddy 服务暂不可用"
        case .invalidResponse: "WorkBuddy 用量返回格式无效"
        case .networkUnavailable: "无法连接 WorkBuddy"
        case .databaseUnavailable: "无法读取 WorkBuddy 近期任务"
        case .localUsageUnavailable: "无法读取 WorkBuddy 本机积分记录"
        }
    }
}

actor WorkBuddyUsageProvider {
    static let endpoint = URL(string: "https://copilot.tencent.com")!
    static let personalUsageURL = endpoint.appendingPathComponent("v2/billing/meter/get-user-resource")
    static let enterpriseUsageURL = endpoint.appendingPathComponent("v2/billing/meter/get-enterprise-user-usage")

    private static let redirectGuard = WorkBuddyRedirectGuard()
    private static let guardedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }()

    private let authURL: URL
    private let databaseURL: URL
    private let projectsURL: URL
    private let cacheURL: URL
    private let session: URLSession
    private let localUsageReader: WorkBuddyLocalUsageReader

    init(
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"),
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db"),
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects", isDirectory: true),
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Notch/WorkBuddyUsageCache.json"),
        session: URLSession? = nil,
        localUsageReader: WorkBuddyLocalUsageReader? = nil
    ) {
        self.authURL = authURL
        self.databaseURL = databaseURL
        self.projectsURL = projectsURL
        self.cacheURL = cacheURL
        self.session = session ?? Self.guardedSession
        self.localUsageReader = localUsageReader ?? .init(databaseURL: databaseURL)
    }

    func fetch(forceLocalUsage: Bool = false) async -> ProviderUsageSnapshot {
        let taskResult = Self.recentTasks(from: databaseURL, projectsURL: projectsURL)
        let tasks: [UsageSessionMetric]
        let taskError: WorkBuddyUsageError?
        switch taskResult {
        case let .success(value):
            tasks = value
            taskError = nil
        case let .failure(error):
            tasks = []
            taskError = error
        }

        let cache = Self.loadCache(from: cacheURL)
        let credentials: WorkBuddyCredentials?
        do {
            let value = try Self.credentials(from: authURL)
            credentials = value
        } catch {
            credentials = nil
        }

        var messages = [taskError?.message].compactMap { $0 }
        var liveUsage: WorkBuddyAccountUsage?
        var accountFetchedAt: Date?
        if let credentials {
            do {
                if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
                    throw WorkBuddyUsageError.credentialsExpired
                }
                liveUsage = try await Self.fetchAccountUsage(credentials: credentials, session: session)
                accountFetchedAt = Date()
            } catch let error as WorkBuddyUsageError {
                messages.append(error.message)
            } catch {
                messages.append(WorkBuddyUsageError.networkUnavailable.message)
            }
        } else {
            messages.append(WorkBuddyUsageError.credentialsMissing.message)
        }

        let localUsage: [WorkBuddyDailyUsage] = switch await localUsageReader.read(force: forceLocalUsage) {
        case let .success(value): value.dailyUsage
        case .failure: []
        }

        let usage = liveUsage ?? cache?.usage
        let fetchedAt = accountFetchedAt ?? cache?.fetchedAt
        if liveUsage != nil || cache == nil {
            Self.save(.init(usage: usage, fetchedAt: fetchedAt), to: cacheURL)
        }
        let message = messages.isEmpty ? nil : messages.joined(separator: " · ")
        guard let usage else {
            return Self.unavailableSnapshot(sessions: tasks, dailyUsage: localUsage, statusMessage: message ?? "未找到 WorkBuddy 数据")
        }
        return Self.snapshot(usage: usage, fetchedAt: fetchedAt, sessions: tasks,
                             dailyUsage: localUsage, statusMessage: message)
    }

    static func credentials(from url: URL) throws -> WorkBuddyCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkBuddyUsageError.credentialsMissing
        }
        guard let data = try? Data(contentsOf: url) else {
            throw WorkBuddyUsageError.credentialsInvalid
        }
        return try credentials(from: data)
    }

    static func credentials(from data: Data) throws -> WorkBuddyCredentials {
        let file: AuthenticationFile
        do {
            file = try JSONDecoder().decode(AuthenticationFile.self, from: data)
        } catch {
            throw WorkBuddyUsageError.credentialsInvalid
        }
        let token = file.auth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = file.account.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !userID.isEmpty else {
            throw WorkBuddyUsageError.credentialsInvalid
        }
        return .init(
            accessToken: token,
            userID: userID,
            enterpriseID: file.account.enterpriseID?.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: file.auth.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: file.auth.expiresAt?.date
        )
    }

    static func personalUsageRequest(credentials: WorkBuddyCredentials) -> URLRequest {
        var request = URLRequest(url: personalUsageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "PageNumber": 1,
            "PageSize": 100,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "OnlyValidPeriod": true,
        ])
        applyHeaders(to: &request, credentials: credentials)
        return request
    }

    static func enterpriseUsageRequest(credentials: WorkBuddyCredentials) -> URLRequest {
        var request = URLRequest(url: enterpriseUsageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = Data("{}".utf8)
        applyHeaders(to: &request, credentials: credentials)
        return request
    }

    static func snapshot(
        usage: WorkBuddyAccountUsage,
        fetchedAt: Date?,
        sessions: [UsageSessionMetric],
        dailyUsage: [WorkBuddyDailyUsage] = [],
        statusMessage: String? = nil
    ) -> ProviderUsageSnapshot {
        let fraction: Double?
        if usage.isUnlimited {
            fraction = nil
        } else if let total = usage.usageTotal, total > 0, let used = usage.usageUsed {
            fraction = min(1, max(0, used / total))
        } else {
            fraction = nil
        }
        let remaining = usage.isUnlimited
            ? "unlimited"
            : creditLabel(usage.usageLeft) + " / " + creditLabel(usage.usageTotal)
        return ProviderUsageSnapshot(
            provider: .workbuddy,
            limits: [
                .init(id: "workbuddy-credits", label: "credits", usedFraction: fraction,
                      resetsAt: usage.refreshAt),
            ],
            stats: [
                .init(id: "workbuddy-remaining", label: "remaining credits", value: remaining, subtitle: nil),
                .init(id: "workbuddy-used", label: "used credits",
                      value: usage.isUnlimited ? "unlimited" : creditLabel(usage.usageUsed), subtitle: nil),
                .init(id: "workbuddy-plan", label: "plan",
                      value: usage.planName ?? usage.editionType ?? "—", subtitle: nil),
                .init(id: "workbuddy-refresh", label: "refresh", value: dateLabel(usage.refreshAt ?? usage.expireAt),
                      subtitle: usage.refreshAt == nil && usage.expireAt != nil ? "expires" : nil),
            ],
            dailySeries: dailyUsage.map { .init(date: $0.date, tokens: 0, credits: $0.credits) },
            chartTitle: "last 7 days · local credits",
            sessionsTitle: "recent tasks",
            sessions: sessions,
            planName: usage.planName ?? usage.editionType,
            source: "WorkBuddy",
            fetchedAt: fetchedAt,
            statusMessage: statusMessage,
            headlineValue: usage.isUnlimited ? "∞" : nil
        )
    }

    static func recentTasks(
        from databaseURL: URL,
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects", isDirectory: true)
    ) -> Result<[UsageSessionMetric], WorkBuddyUsageError> {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .failure(.databaseUnavailable)
        }
        guard let database = openWorkBuddyDatabaseReadOnly(at: databaseURL) else {
            return .failure(.databaseUnavailable)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let sql = """
        SELECT s.id,
               COALESCE(NULLIF(s.custom_title, ''), NULLIF(s.title, ''), 'Untitled task'),
               s.updated_at,
               su.used,
               s.cwd
        FROM sessions s
        LEFT JOIN session_usage su ON su.session_id = s.id
        WHERE s.deleted_at IS NULL OR s.deleted_at = 0
        ORDER BY s.updated_at DESC
        LIMIT 3
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return .failure(.databaseUnavailable)
        }
        defer { sqlite3_finalize(statement) }

        var records: [(id: String, title: String, updatedAt: Double, used: Int?, cwd: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idValue = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idValue)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "Untitled task"
            let updatedAt = sqlite3_column_double(statement, 2)
            let used = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 3))
            let cwd = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            records.append((id, title, updatedAt, used, cwd))
        }
        let transcriptPaths = transcriptPaths(in: projectsURL, sessionIDs: Set(records.map(\.id)))
        let sessions = records.map { record -> UsageSessionMetric in
            let transcriptPath = transcriptPaths[record.id]
            let taskReference: AgentTaskReference?
            if !record.cwd.isEmpty, let transcriptPath {
                taskReference = .init(
                    provider: .workbuddy,
                    sessionID: record.id,
                    title: record.title,
                    cwd: record.cwd,
                    workspaceRoots: [record.cwd],
                    transcriptPath: transcriptPath
                )
            } else {
                taskReference = nil
            }
            return .init(
                id: record.id,
                name: record.title,
                cost: nil,
                tokens: record.used,
                last: Date(timeIntervalSince1970: record.updatedAt / 1_000),
                taskReference: taskReference
            )
        }
        return .success(sessions)
    }

    private static func transcriptPaths(in projectsURL: URL, sessionIDs: Set<String>) -> [String: String] {
        guard !sessionIDs.isEmpty,
              let enumerator = FileManager.default.enumerator(
                  at: projectsURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [:] }
        var paths: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let sessionID = url.deletingPathExtension().lastPathComponent
            guard sessionIDs.contains(sessionID), paths[sessionID] == nil else { continue }
            paths[sessionID] = url.path
            if paths.count == sessionIDs.count { break }
        }
        return paths
    }

    private static func fetchAccountUsage(
        credentials: WorkBuddyCredentials,
        session: URLSession
    ) async throws -> WorkBuddyAccountUsage {
        let request = credentials.enterpriseID?.isEmpty == false
            ? enterpriseUsageRequest(credentials: credentials)
            : personalUsageRequest(credentials: credentials)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https", response.url?.host == endpoint.host else {
                throw WorkBuddyUsageError.networkUnavailable
            }
            switch response.statusCode {
            case 200:
                return try usage(from: data, enterprise: credentials.enterpriseID?.isEmpty == false)
            case 401: throw WorkBuddyUsageError.unauthorized
            case 429: throw WorkBuddyUsageError.rateLimited
            case 500...599: throw WorkBuddyUsageError.serviceUnavailable
            default: throw WorkBuddyUsageError.networkUnavailable
            }
        } catch let error as WorkBuddyUsageError {
            throw error
        } catch {
            throw WorkBuddyUsageError.networkUnavailable
        }
    }

    static func usage(from data: Data, enterprise: Bool) throws -> WorkBuddyAccountUsage {
        try enterprise ? enterpriseUsage(from: data) : personalUsage(from: data)
    }

    private static func personalUsage(from data: Data) throws -> WorkBuddyAccountUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = nested(root, keys: ["data", "Response", "Data", "Accounts"]) as? [[String: Any]] else {
            throw WorkBuddyUsageError.invalidResponse
        }
        let resources = accounts.map { resource -> WorkBuddyResource in
            let total = number(resource["CycleCapacitySizePrecise"]) ?? 0
            let left = number(resource["CycleCapacityRemainPrecise"]) ?? 0
            return WorkBuddyResource(
                name: string(resource["PackageName"]) ?? "",
                total: total,
                left: left,
                refreshAt: date(resource["CycleEndTime"]),
                expireAt: date(resource["DeductionEndTime"]) ?? date(resource["ExpiredTime"])
            )
        }
        let total = resources.reduce(0.0) { $0 + $1.total }
        let left = resources.reduce(0.0) { $0 + $1.left }
        let plan = resources.first(where: { !$0.name.isEmpty })
        return .init(
            usageLeft: left,
            usageTotal: total,
            usageUsed: max(0, total - left),
            planName: plan?.name.nilIfEmpty,
            editionType: nil,
            refreshAt: plan?.refreshAt,
            expireAt: plan?.expireAt,
            isUnlimited: false
        )
    }

    private static func enterpriseUsage(from data: Data) throws -> WorkBuddyAccountUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkBuddyUsageError.invalidResponse
        }
        let payload = (nested(root, keys: ["data", "data"]) as? [String: Any])
            ?? (root["data"] as? [String: Any])
            ?? root
        guard let limit = number(payload["limitNum"]) else {
            throw WorkBuddyUsageError.invalidResponse
        }
        let used = number(payload["credit"]) ?? 0
        if limit == -1 {
            return .init(usageLeft: nil, usageTotal: nil, usageUsed: nil, planName: nil,
                         editionType: "enterprise", refreshAt: date(payload["cycleResetTime"]),
                         expireAt: nil, isUnlimited: true)
        }
        return .init(
            usageLeft: max(0, limit - used),
            usageTotal: limit,
            usageUsed: used,
            planName: nil,
            editionType: "enterprise",
            refreshAt: date(payload["cycleResetTime"]),
            expireAt: nil,
            isUnlimited: false
        )
    }

    private static func unavailableSnapshot(
        sessions: [UsageSessionMetric],
        dailyUsage: [WorkBuddyDailyUsage],
        statusMessage: String
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: .workbuddy,
            stats: [
                .init(id: "workbuddy-remaining", label: "remaining credits", value: "—", subtitle: nil),
                .init(id: "workbuddy-used", label: "used credits", value: "—", subtitle: nil),
                .init(id: "workbuddy-plan", label: "plan", value: "—", subtitle: nil),
                .init(id: "workbuddy-refresh", label: "refresh", value: "—", subtitle: nil),
            ],
            dailySeries: dailyUsage.map { .init(date: $0.date, tokens: 0, credits: $0.credits) },
            chartTitle: "last 7 days · local credits",
            sessionsTitle: "recent tasks",
            sessions: sessions,
            source: "WorkBuddy",
            statusMessage: statusMessage
        )
    }

    private static func applyHeaders(to request: inout URLRequest, credentials: WorkBuddyCredentials) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.userID, forHTTPHeaderField: "X-User-Id")
        if let enterpriseID = credentials.enterpriseID, !enterpriseID.isEmpty {
            request.setValue(enterpriseID, forHTTPHeaderField: "X-Enterprise-Id")
            request.setValue(enterpriseID, forHTTPHeaderField: "X-Tenant-Id")
        }
        if let domain = credentials.domain, !domain.isEmpty {
            request.setValue(domain, forHTTPHeaderField: "X-Domain")
        }
    }

    private static func loadCache(from url: URL) -> WorkBuddyUsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkBuddyUsageCache.self, from: data)
    }

    private static func save(_ cache: WorkBuddyUsageCache, to url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func nested(_ root: [String: Any], keys: [String]) -> Any? {
        keys.reduce(root as Any?) { current, key in
            (current as? [String: Any])?[key]
        }
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let string = string(value) else { return nil }
        if let number = Double(string) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func creditLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value.rounded() == value { return "\(Int(value))" }
        return String(format: "%.2f", value)
    }

    private static func dateLabel(_ value: Date?) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: value)
    }
}

private struct AuthenticationFile: Decodable {
    let account: Account
    let auth: Auth

    struct Account: Decodable {
        let uid: String
        let enterpriseID: String?

        enum CodingKeys: String, CodingKey {
            case uid
            case enterpriseID = "enterpriseId"
        }
    }

    struct Auth: Decodable {
        let accessToken: String
        let domain: String?
        let expiresAt: FlexibleEpoch?
    }
}

private struct FlexibleEpoch: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            date = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        } else {
            date = nil
        }
    }
}

private struct WorkBuddyResource {
    let name: String
    let total: Double
    let left: Double
    let refreshAt: Date?
    let expireAt: Date?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class WorkBuddyRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
