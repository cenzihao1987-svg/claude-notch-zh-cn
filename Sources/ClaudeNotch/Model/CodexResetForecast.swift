import Foundation

/// codex-reset.com 提供的非敏感事实。每个字段都可选：接口随时可能少给一项，
/// 少一项只应该让格子少一行，不应该让整个格子消失。
struct CodexResetForecast: Equatable, Sendable {
    /// 距上次确认重置的天数，一位小数。来自 `/api/forecast` 的 `age_days`。
    var ageDays: Double?
    /// 近期几次重置的间隔中位数。来自 `/api/forecast` 的 `cadence.recent_median_days`。
    var recentMedianDays: Double?
    /// Tibo 原话被解析出的英文窗口措辞，例如 "within an hour"。
    var officialWindowLabel: String?
    /// 那个窗口的结束时刻。既用来判断预告是否过期，也用来算倒计时。
    var officialWindowEnd: Date?
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
            ?? announcedWindow(forecast, now: now)
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

    // MARK: - 优先级 2：Tibo 预告

    /// 过期判断放在渲染时再做一次（而不是只在取数时做）：缓存值可能已经躺了 6 小时，
    /// 那时窗口早就关了。宁可降级到优先级 3，也不能显示一个已经作废的预告。
    private static func announcedWindow(
        _ forecast: CodexResetForecast?,
        now: Date
    ) -> UsageStatMetric? {
        // 先解包整个 forecast 再取字段。写成 `forecast?.officialWindowLabel` 会得到
        // String??（对可选属性做可选链会多包一层），传不进 windowLabel。
        guard let forecast, let end = forecast.officialWindowEnd, end > now else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "Tibo 预告",
            value: windowLabel(forecast.officialWindowLabel),
            subtitle: "约 \(lead(end.timeIntervalSince(now))) 后"
        )
    }

    /// 只翻译见过的确切字符串，其余一律「有预告」。
    ///
    /// 不猜译：`in a bit` 译成「稍后」可能被读成「还早」，做出相反决策。
    /// 也不显示英文原文：`official hint — timing unspecified` 有 34 个字符，
    /// 格子只有 121pt 宽，必然溢出。「有预告」对任何 label 都成立，
    /// 真正可操作的时间在副行 —— 那是 `end_at` 算出来的，不经过任何文本理解。
    private static func windowLabel(_ raw: String?) -> String {
        switch raw {
        case "within an hour", "within the hour": return "1 小时内"
        case "within 30 minutes": return "30 分钟内"
        case "within a few hours": return "几小时内"
        case "later today": return "今天内"
        case "official hint — timing unspecified": return "时间未定"
        default: return "有预告"
        }
    }

    /// "40 分钟" / "2 小时 47 分" / "2 天"。
    /// 比 Fmt.until 粗：预告窗口可以横跨两天（"end of Monday"），也可以只剩几分钟，
    /// 一个格式化器同时照顾两端会很别扭，所以这里单独写一个。
    private static func lead(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { return "\(s / 86_400) 天" }
        if s >= 3_600 {
            let h = s / 3_600, m = (s % 3_600) / 60
            return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时"
        }
        return "\(max(1, s / 60)) 分钟"
    }

    // MARK: - 优先级 3：节奏事实

    /// 显示事实而非概率。接口给的 `rounded_24h: 30` 在它自己的 backtest 里
    /// 只比基线好 3%（brier 0.100 vs 0.103），基本是个常数，看一年也不会变。
    /// 「距上次 5.1 天 · 近期 2.3 天一轮」让用户自己判断「超期一倍了」。
    private static func cadenceFacts(_ forecast: CodexResetForecast?) -> UsageStatMetric? {
        // 同上，先解包 forecast，否则 subtitle 会是 String?? 而不是 String?。
        guard let forecast, let age = forecast.ageDays else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "距上次重置",
            value: String(format: "%.1f 天", age),
            subtitle: forecast.recentMedianDays.map { String(format: "近期 %.1f 天一轮", $0) }
        )
    }
}
