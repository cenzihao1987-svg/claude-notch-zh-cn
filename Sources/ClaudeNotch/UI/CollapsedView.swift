import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)小时\(String(format: "%02d", m % 60))分"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    /// "40分" / "1小时10分" / "4天17小时" —— 剩余时间。不足 1 小时时不写「0小时」，
    /// 因为重置格子会把这个字符串当主数值放大显示，「0小时40分」在那个位置很刺眼。
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(String(format: "%02d", m))分" }
        return "\(m)分"
    }
    /// "35m" / "1h 05m" — a duration.
    static func dur(_ t: TimeInterval) -> String {
        let m = max(0, Int(t) / 60)
        return m >= 60 ? "\(m / 60)小时\(String(format: "%02d", m % 60))分" : "\(m)分"
    }
    /// "4s" / "2m" / "1h" / "2d" — compact age of a timestamp.
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "\(s)秒" }
        if s < 3600 { return "\(s / 60)分" }
        if s < 86_400 { return "\(s / 3600)小时" }
        return "\(s / 86_400)天"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    /// Money from API minor units + ISO currency code, e.g. (4251, "EUR") -> "€42.51".
    /// Assumes 2 decimal places, which matches every currency claude.ai bills in.
    static func money(minor: Int, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "en_US")   // stable symbol-first formatting: €42.51, $42.51
        return f.string(from: NSNumber(value: Double(minor) / 100)) ?? String(format: "%.2f %@", Double(minor) / 100, currency)
    }

    /// "default_claude_max_5x" -> "Claude Max 5x"; "…_pro" -> "Claude Pro".
    static func planLabel(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "default_", with: "")
                   .replacingOccurrences(of: "claude_", with: "")
        if s.hasPrefix("max_") {
            s = s.replacingOccurrences(of: "max_", with: "")
            return "Claude Max \(s)"          // "5x"
        }
        return "Claude " + s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Ring colour thresholds for a usage fraction (0…1 consumed).
func ringState(for used: Double) -> RingState {
    switch used {
    case ..<0.66: return .ok
    case ..<0.85: return .warn
    default:      return .critical
    }
}

/// Ring colour thresholds for a remaining fraction (0…1 available).
func remainingRingState(for remaining: Double) -> RingState {
    switch remaining {
    case ...0.15: return .critical
    case ...0.34: return .warn
    default:      return .ok
    }
}
