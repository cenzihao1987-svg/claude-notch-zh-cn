import Foundation

enum CodexResetSource {
    static let websiteURL = URL(string: "https://codex-resets.com/")!
    static let statusEndpointURL = URL(string: "https://codex-resets.com/api/v1/status")!
}

/// codex-resets.com 提供的非敏感事实。每个字段都可选：接口随时可能少给一项，
/// 少一项只应该让格子少一行，不应该让整个格子消失。
struct CodexResetForecast: Equatable, Sendable {
    /// 距上次确认重置的天数。来自 `/api/v1/status` 的 `stats.days_since_last`。
    var ageDays: Double?
    /// 全部重置历史的平均间隔。来自 `stats.avg_interval_days`。
    var averageIntervalDays: Double?
    /// 站点 AI 分类出的活动观察信号概率；不是 OpenAI 官方承诺。
    var watchChancePercent: Int?
    /// 观察信号的过期时间，只用于判断信号是否仍有效。
    var watchExpiresAt: Date?
}

/// 决定「重置」格子显示什么。
///
/// 固定优先级，不做「谁更早显示谁」：本地倒计时是确定的，Tibo 预告是可能的，
/// 两者不可比。规则可预测比规则最优更重要 —— 用户扫一眼就得知道自己在看什么。
enum CodexResetTile {
    /// 本地窗口进入这个区间就抢占格子。3 小时来自设计文档，不做成可调参数。
    private static let imminentThreshold: TimeInterval = 3 * 3_600

    /// 永远返回一个格子。没有任何数据时返回「重置 / —」，
    /// 这样六宫格始终是满的，不会因为断网塌成五个格子。
    static func make(
        limits: [UsageLimitMetric],
        forecast: CodexResetForecast?,
        now: Date
    ) -> UsageStatMetric {
        imminentLocalReset(limits, now: now)
            ?? watchSignal(forecast, now: now)
            ?? cadenceFacts(forecast)
            ?? UsageStatMetric(id: "reset", label: "重置", value: "—", subtitle: nil)
    }

    // MARK: - 优先级 1：本地额度即将重置

    /// `now` 决定选哪个窗口；渲染出的字符串走 `Fmt.until`，和旁边额度格子的
    /// 「X 后重置」用同一个格式化器，两处数字必须长得一样。
    private static func imminentLocalReset(
        _ limits: [UsageLimitMetric],
        now: Date
    ) -> UsageStatMetric? {
        let candidates = limits.compactMap { metric -> (date: Date, label: String)? in
            guard let resets = metric.resetsAt else { return nil }
            let remaining = resets.timeIntervalSince(now)
            guard remaining > 0, remaining <= imminentThreshold else { return nil }
            return (resets, metric.label)
        }
        guard let soonest = candidates.min(by: { $0.date < $1.date }) else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "即将重置",
            value: Fmt.until(soonest.date),
            subtitle: windowName(soonest.label)
        )
    }

    /// "5-Hour" 或 "Codex · 5-Hour" -> "5 小时窗口"。
    /// 分隔逻辑与 CodexUsageProvider.durationOrder 一致：桶名在前，时长在后。
    ///
    /// 设计文档说这一行来自 `windowDurationMins`，但 UsageLimitMetric 只带格式化好的
    /// label，不带原始分钟数。label 本来就是 durationLabel(windowDurationMins) 的产物，
    /// 从它反解等价，且不用为了一个副行去改模型。
    private static func windowName(_ label: String) -> String {
        let duration = label.split(separator: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
        switch duration {
        case "5-Hour": return "5 小时窗口"
        case "Daily": return "每日窗口"
        case "7-Day": return "7 天窗口"
        case "Monthly": return "每月窗口"
        case "Annual": return "每年窗口"
        default:
            if duration.hasSuffix("-Hour"), let v = Int(duration.dropLast(5)) { return "\(v) 小时窗口" }
            if duration.hasSuffix("-Day"), let v = Int(duration.dropLast(4)) { return "\(v) 天窗口" }
            if duration.hasSuffix("-Min"), let v = Int(duration.dropLast(4)) { return "\(v) 分钟窗口" }
            return duration
        }
    }

    // MARK: - 优先级 2：Tibo 信号

    /// `active_watch` 是站点的 AI 分类预测，不是官方承诺。过期判断在渲染时再做一次，
    /// 避免缓存值已经失效时仍显示信号。详情交给可点击的网站卡片承载。
    private static func watchSignal(
        _ forecast: CodexResetForecast?,
        now: Date
    ) -> UsageStatMetric? {
        guard let forecast, let end = forecast.watchExpiresAt, end > now else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "Tibo 信号",
            value: forecast.watchChancePercent.map { "\($0)%" } ?? "关注中",
            subtitle: "点击查看详情"
        )
    }

    // MARK: - 优先级 3：节奏事实

    /// 概率缺失时的兜底（接口降级成 heuristic 模式时会没有 probabilities）。
    /// 「距上次 6.0 天 · 近期 2.3 天一轮」让用户自己判断「超期了」。
    private static func cadenceFacts(_ forecast: CodexResetForecast?) -> UsageStatMetric? {
        // 同上，先解包 forecast，否则 subtitle 会是 String?? 而不是 String?。
        guard let forecast, let age = forecast.ageDays else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "距上次重置",
            value: String(format: "%.1f 天", age),
            subtitle: forecast.averageIntervalDays.map { String(format: "平均 %.1f 天一轮", $0) }
        )
    }
}
