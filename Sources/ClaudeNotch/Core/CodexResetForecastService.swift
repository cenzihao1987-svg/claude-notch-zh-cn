import Foundation
import os

/// 读 codex-resets.com 的免费公开接口。不带任何凭据，只取网站公开的只读 JSON。
actor CodexResetForecastService {
    private static let log = Logger(subsystem: "com.claudenotch.app", category: "reset")

    /// API 自带 30 秒缓存；应用只在查看 Codex 时请求。15 分钟足以覆盖短时观察信号，
    /// 同时把匿名免费接口的调用量控制在每天最多 96 次。
    private static let staleAfter: TimeInterval = 15 * 60
    /// 失败后的重试间隔。没有它，断网时展开态每 30 秒就会重试一次。
    private static let retryAfterFailure: TimeInterval = 15 * 60

    private var cached: CodexResetForecast?
    /// 上次**成功**的时刻，驱动 6 小时新鲜度判断。
    private var succeededAt: Date?
    /// 上次**尝试**的时刻（成功失败都记），驱动失败退避。
    private var attemptedAt: Date?

    /// 已有的值，不碰网络。
    func current() -> CodexResetForecast? { cached }

    /// 数据过期就拉一次。
    /// - Returns: 缓存值是否真的变了。调用方据此决定要不要重画一次界面；
    ///            返回 false 时不重画，避免「拉取 → 重画 → 又拉取」的死循环。
    @discardableResult
    func refreshIfStale(now: Date = Date()) async -> Bool {
        if let succeededAt, now.timeIntervalSince(succeededAt) < Self.staleAfter { return false }
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < Self.retryAfterFailure { return false }
        attemptedAt = now

        guard let fresh = await Self.load() else {
            // 断网或对方改了结构：继续供应上一份好数据，等下一轮再试。
            // 绝不把一个正在正常显示的格子清空。
            Self.log.notice("reset forecast fetch failed, keeping cached value")
            return false
        }

        succeededAt = now
        guard fresh != cached else { return false }
        cached = fresh
        // 单行字符串：os.Logger 的 OSLogMessage 对多行字面量支持不稳，不要拆行。
        Self.log.notice("reset forecast updated: age=\(fresh.ageDays ?? -1, privacy: .public)d average=\(fresh.averageIntervalDays ?? -1, privacy: .public)d watch=\(fresh.watchChancePercent ?? -1, privacy: .public)")
        return true
    }

    // MARK: - 取数

    private static func load() async -> CodexResetForecast? {
        guard let data = await get(CodexResetSource.statusEndpointURL) else { return nil }
        return decodeStatus(data)
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeNotch", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    nonisolated static func decodeStatus(_ data: Data) -> CodexResetForecast? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(StatusPayload.self, from: data) else { return nil }
        return CodexResetForecast(
            ageDays: payload.data.stats.daysSinceLast,
            averageIntervalDays: payload.data.stats.avgIntervalDays,
            watchChancePercent: payload.data.activeWatch?.resetChancePercent,
            watchExpiresAt: payload.data.activeWatch.flatMap { parseISO($0.expiresAt) }
        )
    }

    /// end_at 形如 "2026-08-13T02:01:37.000Z"，少数早期记录没有小数秒。
    /// 双 formatter 的写法与 ClaudeDesktopUsageCache 里的一致。
    private static func parseISO(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: - JSON 结构
    // 只声明用得到的字段。多余的键 JSONDecoder 默认忽略，对方加字段不会把我们打挂。

    private struct StatusPayload: Decodable {
        struct PayloadData: Decodable {
            struct Stats: Decodable {
                let daysSinceLast: Double?
                let avgIntervalDays: Double?
            }
            struct Watch: Decodable {
                let resetChancePercent: Int?
                let expiresAt: String
            }
            let activeWatch: Watch?
            let stats: Stats
        }
        let data: PayloadData
    }
}
