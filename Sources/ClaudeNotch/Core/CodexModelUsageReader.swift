import Foundation

struct CodexModelUsageCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String
}

enum CodexModelUsageError: Error, Equatable, Sendable {
    case credentialsMissing
    case credentialsInvalid
    case unauthorized
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case networkUnavailable
}

/// Reads the same read-only seven-day model breakdown used by Codex's Analysis settings page.
/// Credentials and raw responses stay in memory and are never logged or persisted by this app.
actor CodexModelUsageReader {
    static let endpointURL = URL(
        string: "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown"
    )!
    static let successTTL: TimeInterval = 60
    static let failureTTL: TimeInterval = 5 * 60

    private static let redirectGuard = CodexModelUsageRedirectGuard()
    private static let guardedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
    }()

    private let authURL: URL
    private let session: URLSession
    private var cached: (series: [DailyUsagePoint], at: Date)?
    private var failedAt: Date?
    private var inFlight: Task<Result<[DailyUsagePoint], CodexModelUsageError>, Never>?

    init(
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        session: URLSession? = nil
    ) {
        self.authURL = authURL
        self.session = session ?? Self.guardedSession
    }

    func fetch(now: Date = Date()) async -> [DailyUsagePoint]? {
        if let cached, now.timeIntervalSince(cached.at) < Self.successTTL {
            return cached.series
        }
        if let failedAt, now.timeIntervalSince(failedAt) < Self.failureTTL {
            return nil
        }
        if let inFlight {
            return try? await inFlight.value.get()
        }

        let authURL = authURL
        let session = session
        let task = Task<Result<[DailyUsagePoint], CodexModelUsageError>, Never> {
            await Self.load(authURL: authURL, session: session, now: now)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil

        switch result {
        case let .success(series):
            cached = (series, now)
            failedAt = nil
            return series
        case .failure:
            failedAt = now
            return nil
        }
    }

    static func credentials(from data: Data) throws -> CodexModelUsageCredentials {
        struct AuthFile: Decodable {
            struct Tokens: Decodable {
                let accessToken: String?
                let accountID: String?

                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case accountID = "account_id"
                }
            }

            let authMode: String?
            let tokens: Tokens?

            enum CodingKeys: String, CodingKey {
                case authMode = "auth_mode"
                case tokens
            }
        }

        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            throw CodexModelUsageError.credentialsInvalid
        }
        guard file.authMode == "chatgpt",
              let accessToken = file.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let accountID = file.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !accountID.isEmpty
        else { throw CodexModelUsageError.credentialsInvalid }
        return CodexModelUsageCredentials(accessToken: accessToken, accountID: accountID)
    }

    static func request(
        credentials: CodexModelUsageCredentials,
        now: Date = Date(),
        calendar: Calendar = utcCalendar
    ) -> URLRequest {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        components.queryItems = [
            URLQueryItem(name: "start_date", value: dayString(start, calendar: calendar)),
            URLQueryItem(name: "end_date", value: dayString(today, calendar: calendar)),
            URLQueryItem(name: "group_by", value: "day"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func dailySeries(
        from data: Data,
        now: Date = Date(),
        calendar: Calendar = utcCalendar
    ) throws -> [DailyUsagePoint] {
        struct Payload: Decodable {
            struct Day: Decodable {
                struct Model: Decodable {
                    let model: String
                    let credits: Double
                }
                let date: String
                let models: [Model]?
            }
            let data: [Day]
            let units: String
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.units == "percent"
        else { throw CodexModelUsageError.invalidResponse }

        var valuesByDay: [String: [String: Double]] = [:]
        for day in payload.data {
            let key = String(day.date.prefix(10))
            guard key.count == 10 else { continue }
            var values = valuesByDay[key] ?? [:]
            for model in day.models ?? [] {
                let name = model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !name.isEmpty, model.credits.isFinite else { continue }
                values[name, default: 0] += max(0, model.credits)
            }
            valuesByDay[key] = values
        }

        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let values = valuesByDay[dayString(date, calendar: calendar)] ?? [:]
            let segments = values.map { ModelUsageSegment(model: $0.key, value: $0.value) }
                .sorted { $0.model < $1.model }
            return DailyUsagePoint(date: date, tokens: 0, modelUsage: segments)
        }
    }

    static func isOfficialURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == endpointURL.scheme
            && url.host == endpointURL.host
            && url.path == endpointURL.path
    }

    private static func load(
        authURL: URL,
        session: URLSession,
        now: Date
    ) async -> Result<[DailyUsagePoint], CodexModelUsageError> {
        guard let authData = try? Data(contentsOf: authURL) else {
            return .failure(.credentialsMissing)
        }
        let credentials: CodexModelUsageCredentials
        do {
            credentials = try Self.credentials(from: authData)
        } catch let error as CodexModelUsageError {
            return .failure(error)
        } catch {
            return .failure(.credentialsInvalid)
        }

        do {
            let (data, response) = try await session.data(for: request(credentials: credentials, now: now))
            guard let response = response as? HTTPURLResponse,
                  isOfficialURL(response.url) else { return .failure(.networkUnavailable) }
            switch response.statusCode {
            case 200:
                return Result { try dailySeries(from: data, now: now) }
                    .mapError { ($0 as? CodexModelUsageError) ?? .invalidResponse }
            case 401, 403: return .failure(.unauthorized)
            case 429: return .failure(.rateLimited)
            case 500...599: return .failure(.serviceUnavailable)
            default: return .failure(.networkUnavailable)
            }
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private final class CodexModelUsageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(CodexModelUsageReader.isOfficialURL(request.url) ? request : nil)
    }
}
