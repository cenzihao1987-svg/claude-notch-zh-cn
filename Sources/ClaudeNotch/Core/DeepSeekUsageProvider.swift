import Foundation

struct DeepSeekBalanceResponse: Decodable, Sendable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct DeepSeekBalanceInfo: Decodable, Sendable, Equatable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

enum DeepSeekUsageError: Error, Equatable, Sendable {
    case configurationMissing
    case configurationInvalid
    case configurationNotFound
    case unauthorized
    case insufficientBalance
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case networkUnavailable

    var message: String {
        switch self {
        case .configurationMissing: "未找到 DeepSeek 配置"
        case .configurationInvalid: "DeepSeek 配置格式无效"
        case .configurationNotFound: "未找到可用 DeepSeek 配置"
        case .unauthorized: "DeepSeek API Key 无效"
        case .insufficientBalance: "DeepSeek 余额不足"
        case .rateLimited: "DeepSeek 请求过于频繁"
        case .serviceUnavailable: "DeepSeek 服务暂不可用"
        case .invalidResponse: "DeepSeek 返回格式无效"
        case .networkUnavailable: "无法连接 DeepSeek"
        }
    }
}

actor DeepSeekUsageProvider {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let redirectGuard = DeepSeekRedirectGuard()
    private static let guardedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }()

    private let configURL: URL
    private let session: URLSession

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/config.json"),
        session: URLSession? = nil
    ) {
        self.configURL = configURL
        self.session = session ?? Self.guardedSession
    }

    func fetch() async -> Result<ProviderUsageSnapshot, DeepSeekUsageError> {
        let key: String
        do {
            key = try Self.apiKey(from: configURL)
        } catch let error as DeepSeekUsageError {
            return .failure(error)
        } catch {
            return .failure(.configurationInvalid)
        }

        var request = Self.balanceRequest(apiKey: key)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https", response.url?.host == "api.deepseek.com" else {
                return .failure(.networkUnavailable)
            }
            switch response.statusCode {
            case 200:
                guard let payload = try? JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data) else {
                    return .failure(.invalidResponse)
                }
                return .success(Self.snapshot(from: payload, fetchedAt: Date()))
            case 401: return .failure(.unauthorized)
            case 402: return .failure(.insufficientBalance)
            case 429: return .failure(.rateLimited)
            case 500...599: return .failure(.serviceUnavailable)
            default: return .failure(.networkUnavailable)
            }
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    static func balanceRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func apiKey(from configURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw DeepSeekUsageError.configurationMissing
        }
        guard let data = try? Data(contentsOf: configURL) else {
            throw DeepSeekUsageError.configurationInvalid
        }
        return try apiKey(from: data)
    }

    static func apiKey(from data: Data) throws -> String {
        let config: ConfigFile
        do {
            config = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            throw DeepSeekUsageError.configurationInvalid
        }
        guard let key = config.responsesUpstream.lazy
            .filter(\.isOfficialDeepSeek)
            .compactMap({ upstream in
                upstream.apiKeys.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            })
            .first
        else {
            throw DeepSeekUsageError.configurationNotFound
        }
        return key
    }

    static func snapshot(from response: DeepSeekBalanceResponse, fetchedAt: Date) -> ProviderUsageSnapshot {
        let infos = response.balanceInfos
        let total = labels(for: infos, keyPath: \.totalBalance)
        let toppedUp = labels(for: infos, keyPath: \.toppedUpBalance)
        let granted = labels(for: infos, keyPath: \.grantedBalance)
        let headline = infos.first(where: { $0.currency == "CNY" }) ?? infos.first(where: { $0.currency == "USD" })
            ?? infos.first
        return ProviderUsageSnapshot(
            provider: .deepseek,
            stats: [
                .init(id: "deepseek-total-balance", label: "total balance", value: total, subtitle: nil),
                .init(id: "deepseek-topped-up-balance", label: "topped-up balance", value: toppedUp, subtitle: nil),
                .init(id: "deepseek-granted-balance", label: "granted balance", value: granted, subtitle: nil),
                .init(id: "deepseek-api-status", label: "API status",
                      value: response.isAvailable ? "available" : "unavailable", subtitle: nil),
            ],
            source: "DeepSeek API",
            fetchedAt: fetchedAt,
            headlineValue: headline.map { label($0.totalBalance, currency: $0.currency) }
        )
    }

    private static func labels(for infos: [DeepSeekBalanceInfo], keyPath: KeyPath<DeepSeekBalanceInfo, String>) -> String {
        let values = infos.map { label($0[keyPath: keyPath], currency: $0.currency) }
        return values.isEmpty ? "—" : values.joined(separator: " · ")
    }

    private static func label(_ amount: String, currency: String) -> String {
        guard let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return "—"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let value = formatter.string(from: decimal as NSDecimalNumber) ?? amount
        switch currency {
        case "CNY": return "¥\(value)"
        case "USD": return "$\(value)"
        default: return "\(value) \(currency)"
        }
    }

    private struct ConfigFile: Decodable {
        let responsesUpstream: [Upstream]
    }

    private struct Upstream: Decodable {
        let baseUrl: String
        let apiKeys: [String]
        let serviceType: String
        let status: String

        var isOfficialDeepSeek: Bool {
            guard let url = URL(string: baseUrl) else { return false }
            return status == "active"
                && serviceType == "openai"
                && url.scheme == "https"
                && url.host == "api.deepseek.com"
        }
    }
}

private final class DeepSeekRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https", request.url?.host == "api.deepseek.com" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
