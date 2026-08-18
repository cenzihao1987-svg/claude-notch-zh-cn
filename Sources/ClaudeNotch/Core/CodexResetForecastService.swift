import Foundation
import os

/// 读 codex-reset.com 的公开接口。不带任何凭据，取的就是那个网站自己渲染用的匿名 JSON。
/// 两个端点合计约 42KB，一天最多拉 4 次。
actor CodexResetForecastService {
    private static let log = Logger(subsystem: "com.claudenotch.app", category: "reset")

    /// Tibo 的预告提前量是 30–60 分钟，重置集中在 UTC 的一个 3 小时窗口里，
    /// 这里没有任何东西会在几小时内变化。6 小时把请求量压到一天 4 次以内。
    private static let staleAfter: TimeInterval = 6 * 3_600
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
        Self.log.notice("reset forecast updated: age=\(fresh.ageDays ?? -1, privacy: .public)d window=\(fresh.officialWindowLabel ?? "none", privacy: .public)")
        return true
    }

    // MARK: - 取数

    private static func load() async -> CodexResetForecast? {
        async let forecastTask = get(ForecastPayload.self, "https://codex-reset.com/api/forecast")
        async let timelineTask = get(TimelinePayload.self, "https://codex-reset.com/api/timeline")
        let (forecast, timeline) = await (forecastTask, timelineTask)

        // 只要有一半拿到就算成功：forecast 挂了还能显示预告，timeline 挂了还能显示节奏。
        guard forecast != nil || timeline != nil else { return nil }

        var result = CodexResetForecast(
            ageDays: forecast?.ageDays,
            recentMedianDays: forecast?.cadence?.recentMedianDays,
            officialWindowLabel: nil,
            officialWindowEnd: nil
        )
        // 这里必须用 if let 而不是 `window?.label`：label 本身是 String?，
        // 再走一层可选链就成了 String??，赋不进 officialWindowLabel。
        if let window = timeline.flatMap(liveWindow) {
            result.officialWindowLabel = window.label
            result.officialWindowEnd = window.end
        }
        return result
    }

    /// 尚未关闭的预告里，结束最早的那一条。
    private static func liveWindow(_ timeline: TimelinePayload) -> (label: String?, end: Date)? {
        let now = Date()
        return timeline.events
            .compactMap { event -> (label: String?, end: Date)? in
                guard let window = event.officialWindow,
                      let raw = window.endAt,
                      let end = parseISO(raw),
                      end > now
                else { return nil }
                return (window.label, end)
            }
            .min { $0.end < $1.end }
    }

    private static func get<T: Decodable>(_ type: T.Type, _ urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeNotch", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
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

    private struct ForecastPayload: Decodable {
        struct Cadence: Decodable {
            let recentMedianDays: Double?
        }
        let ageDays: Double?
        let cadence: Cadence?
    }

    private struct TimelinePayload: Decodable {
        struct Event: Decodable {
            struct Window: Decodable {
                let label: String?
                let endAt: String?
            }
            let officialWindow: Window?
        }
        let events: [Event]
    }
}
